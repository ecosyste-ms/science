require "test_helper"
require_relative "../support/swhid_pipeline"
require "tmpdir"
require "open3"

class RepositoryScanWorkerTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    @directory = Dir.mktmpdir("science-repository-test-")
    @source = File.join(@directory, "source with spaces")
    FileUtils.mkdir_p(@source)
    git("init", @source)
    File.write(File.join(@source, "requirements.txt"), "numpy==2.0.0\n")
    File.write(File.join(@source, "main.py"), "import numpy\nprint(numpy.zeros(3))\n")
    File.write(File.join(@source, "main.f90"), "program hello\nprint *, 'hello'\nend program hello\n")
    File.write(File.join(@source, "codemeta.json"), '{"name":"Research software"}')
    git("-C", @source, "add", ".")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Repository input")
    @commit = git("-C", @source, "rev-parse", "HEAD").strip
    @project = Project.create!(url: "https://github.com/test/shared-checkout", science_score: 50,
      joss_metadata: { "title" => "Research software" }, repository: { "clone_url" => @source })
    @previous_trace = ENV["GIT_TRACE2_EVENT"]
    @previous_path = ENV["PATH"]
    @previous_github_token = ENV["GITHUB_TOKEN"]
    ENV.delete("GITHUB_TOKEN")
    @trace = File.join(@directory, "git-trace.jsonl")
    ENV["GIT_TRACE2_EVENT"] = @trace
  end

  teardown do
    @previous_trace ? ENV["GIT_TRACE2_EVENT"] = @previous_trace : ENV.delete("GIT_TRACE2_EVENT")
    ENV["PATH"] = @previous_path
    @previous_github_token ? ENV["GITHUB_TOKEN"] = @previous_github_token : ENV.delete("GITHUB_TOKEN")
    FileUtils.remove_entry(@directory)
  end

  test "Brief selection and project sync share one queued scan and one real checkout" do
    assert_equal 1, BriefScanEnqueuer.new(limit: 1).enqueue
    assert_nil @project.fetch_swhids_async
    assert_equal 1, RepositoryScanWorker.jobs.size

    RepositoryScanWorker.perform_one

    @project.reload
    assert @project.brief.fetch("dependencies").any? { |dependency| dependency["purl"] == "pkg:pypi/numpy" }
    assert_equal "success", @project.swhids["status"]
    assert_equal "swh:1:rev:#{@commit}", @project.swhids.dig("revision", "swhid")
    assert_equal @commit, @project.swhids.fetch("commit")
    assert @project.swhids.dig("metadata", "codemeta", "content_swhid")
    assert_equal 1, clone_commands.size
    checkout = @project.swhids.dig("directory", "input", "path")
    assert_equal checkout, clone_commands.first.last
    assert_not File.exist?(checkout)
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_equal "swh_api", CheckSwhidBatchWorker.jobs.first["queue"]
    assert_not_requested :any, /archive\.softwareheritage\.org/
  end

  test "scan scores Brief dependencies before indexing and refreshes their context" do
    File.write(File.join(@source, "requirements.txt"), "scipy\nastropy\nbiopython\nscipy\n")
    commit_source
    @project.update!(dependencies: [], dependencies_indexed_at: Time.current)
    RepositoryScanWorker.new.perform(@project.id)

    @project.reload
    signal = @project.science_score_breakdown.dig("breakdown", "has_scientific_dependencies")
    assert_equal 3, signal.fetch("matches")
    assert_equal 1.0, signal.fetch("strength")
    assert_nil @project.dependencies_indexed_at
    assert_empty @project.project_dependencies
    Project.sync_dependencies
    assert_equal %w[astropy biopython scipy], @project.reload.project_dependencies.order(:package_name).pluck(:package_name)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get("/api/v1/projects/#{@project.id}/search_context")
    assert_equal 200, session.response.status
    assert_equal %w[astropy biopython scipy], session.response.parsed_body.fetch("direct_dependencies").pluck("name").sort

    File.write(File.join(@source, "requirements.txt"), "scipy\n")
    commit_source
    @project.update!(brief: @project.brief.merge("version" => "0.14.0"))
    RepositoryScanWorker.new.perform(@project.id, false, true)
    assert_nil @project.reload.dependencies_indexed_at
    assert_equal 0.4, @project.science_score_breakdown.dig("breakdown", "has_scientific_dependencies", "strength")
    Project.sync_dependencies
    assert_equal ["scipy"], @project.reload.project_dependencies.pluck(:package_name)

    @project.update!(brief: @project.brief.merge("version" => "0.14.0"))
    RepositoryBriefScan.stubs(:call).raises(RepositoryCommand::Error, "scan failed")
    RepositoryScanWorker.new.perform(@project.id, false, true)
    assert_equal "scan failed", @project.reload.brief.dig("last_error", "error")
    assert_equal 0.4, @project.science_score_breakdown.dig("breakdown", "has_scientific_dependencies", "strength")
  end

  test "scan retains separate R DESCRIPTION claims with file provenance" do
    File.delete(File.join(@source, "codemeta.json"))
    File.write(File.join(@source, "DESCRIPTION"), <<~DCF)
      Package: SNPRelate
      Title: Parallel Computing Toolset for Relatedness
      Description: Analysis of genome-wide SNP data
          with parallel computing.
      URL: https://github.com/zhengxwen/SNPRelate
      BugReports: https://github.com/zhengxwen/SNPRelate/issues
      Authors@R: stop("must not execute")
    DCF
    FileUtils.mkdir_p(File.join(@source, "other"))
    File.write(File.join(@source, "other", "DESCRIPTION"), <<~DCF)
      Package: rpart
      Title: Recursive Partitioning and Regression Trees
      Description: Recursive partitioning
          for classification and regression.
      URL: https://example.org/rpart, https://example.org/rpart/manual (manual)
      BugReports: not a URL
    DCF
    commit_source
    revision = git("-C", @source, "rev-parse", "HEAD").strip
    RepositoryScanWorker.new.perform(@project.id)

    stored = @project.reload.repository.dig("metadata", "r_package_descriptions")
    assert_equal ["DESCRIPTION"], stored.pluck("path")
    assert_equal [revision], stored.pluck("revision").uniq
    assert_equal Digest::SHA256.file(File.join(@source, "DESCRIPTION")).hexdigest, stored.first.fetch("sha256")
    assert stored.first.fetch("retrieved_at").present?
    refute stored.first.fetch("fields").key?("Authors@R")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get("/api/v1/projects/#{@project.id}/search_context")
    assert_equal 200, session.response.status
    manifests = session.response.parsed_body.fetch("package_manifests")
    assert_equal ["SNPRelate"], manifests.map { |item| item.fetch("names").sole.fetch("value") }
    assert_equal "Analysis of genome-wide SNP data with parallel computing.", manifests.first.fetch("descriptions").sole.fetch("value")
    assert_empty session.response.parsed_body.fetch("packages")
    assert manifests.all? { |item| item.fetch("url").include?(revision) }

    stub_request(:get, @project.repos_api_url).to_return(body: { "clone_url" => @source, "metadata" => { "upstream" => true } }.to_json)
    @project.fetch_repository
    assert_equal stored, @project.reload.repository.dig("metadata", "r_package_descriptions")
    assert @project.repository.dig("metadata", "upstream")

    FileUtils.cp(File.join(@source, "other", "DESCRIPTION"), File.join(@source, "DESCRIPTION"))
    commit_source
    @project.update!(brief: @project.brief.merge("version" => "0.14.0"))
    RepositoryScanWorker.new.perform(@project.id, false, true)
    session.get("/api/v1/projects/#{@project.id}/search_context")
    manifest = session.response.parsed_body.fetch("package_manifests").sole
    assert_equal "rpart", manifest.fetch("names").sole.fetch("value")
    assert_equal ["https://example.org/rpart", "https://example.org/rpart/manual"], manifest.fetch("urls").pluck("value")
    assert_empty manifest.fetch("bug_reports")
  end

  def commit_source
    git("-C", @source, "add", ".")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Update repository input")
  end

  test "scan and paper import workers retain publisher DOI citation evidence and suppress duplicate credit" do
    previous_key = ENV["OPENALEX_API_KEY"]
    ENV["OPENALEX_API_KEY"] = "test-key"
    FileUtils.mkdir_p(File.join(@source, "inst"))
    publisher_url = "https://link.springer.com/article/10.1186/1471-2105-9-559"
    citation = "bibentry(bibtype = 'Article', title = 'WGCNA: an R package for weighted correlation network analysis', url = '#{publisher_url}')\n"
    File.write(File.join(@source, "inst", "CITATION"), citation)
    commit_source
    @project.update!(joss_metadata: nil)
    RepositoryScanWorker.new.perform(@project.id)
    assert_equal citation, @project.reload.citation_file
    assert @project.science_score_breakdown.dig("breakdown", "has_citation_file", "present")
    assert_equal 0.5, @project.science_score_breakdown.dig("breakdown", "has_citation_file", "strength")
    before_score = @project.science_score
    assert_empty @project.project_papers
    work = { "id" => "https://openalex.org/W123", "title" => "WGCNA: an R package for weighted correlation network analysis",
      "doi" => "https://doi.org/10.1186/1471-2105-9-559" }
    request = stub_request(:get, "https://api.openalex.org/works/doi:10.1186/1471-2105-9-559")
      .with(query: { "api_key" => "test-key" }).to_return({ status: 404 }, { body: work.to_json })
    ImportProjectPapersWorker.new.perform(@project.id)
    assert_empty @project.reload.project_papers
    assert_equal before_score, @project.science_score
    ImportProjectPapersWorker.new.perform(@project.id)
    link = @project.reload.project_papers.sole
    assert_equal "reference", link.role
    assert_equal "10.1186/1471-2105-9-559", link.paper.doi
    evidence = link.evidence.sole
    assert_equal "inst/CITATION", evidence.fetch("file_path")
    assert_equal @project.brief.fetch("revision"), evidence.fetch("revision")
    assert_equal Digest::SHA256.hexdigest(citation), evidence.fetch("file_sha256")
    assert_includes evidence.fetch("occurrences").sole.fetch("raw"), publisher_url
    assert_equal 20, @project.science_score_breakdown.dig("breakdown", "has_resolved_paper", "score")
    assert_in_delta 12, @project.science_score - before_score
    assert_equal "has_resolved_paper", @project.science_score_breakdown.dig("breakdown", "has_citation_file", "duplicate_of")
    assert_requested request, times: 2
  ensure
    ENV["OPENALEX_API_KEY"] = previous_key
  end

  test "queued legacy workers use the shared checkout and skip completed analyses" do
    FetchBriefWorker.new.perform(@project.id)
    FetchSwhidWorker.new.perform(@project.id)
    RepositoryScanWorker.new.perform(@project.id)

    assert_equal 1, clone_commands.size
    assert_equal "success", @project.reload.swhids["status"]
    assert @project.brief.key?("dependencies")
  end

  test "a scan names the project from codemeta rather than README notices" do
    readme = "# ***ATTENTION***\n\nPlease direct questions to the support forum.\n\n# Shared Checkout User Manual\n"
    File.write(File.join(@source, "README.md"), readme)
    git("-C", @source, "add", "README.md")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Add README")

    RepositoryScanWorker.new.perform(@project.id)

    assert_equal "Research software", @project.reload.name
  end

  test "successful repository scans enqueue paper imports for stored READMEs" do
    previous_key = ENV["OPENALEX_API_KEY"]
    ENV["OPENALEX_API_KEY"] = "test-key"
    File.write(File.join(@source, "README.md"), "# Research software\n\nhttps://doi.org/10.1234/example\n")
    git("-C", @source, "add", "README.md")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Add README")
    assert_difference "ImportProjectPapersWorker.jobs.size", 1 do
      RepositoryScanWorker.new.perform(@project.id)
    end
    assert_equal [@project.id], ImportProjectPapersWorker.jobs.last["args"]
  ensure
    ENV["OPENALEX_API_KEY"] = previous_key
  end

  test "queued scan preserves citation file and README BibTeX with diagnostics" do
    File.write(File.join(@source, "CITATION.bib"), <<~BIBTEX)
      @article{paper,
        title = {Research software},
        author = {Smith, Alice},
        doi = {10.1234/example}
      }
    BIBTEX
    File.write(File.join(@source, "README.md"), <<~MARKDOWN)
      # Research software

      Please cite the model paper:

      ```bibtex
      @article{model,
        author = {Smith, Alice}
        title = {A model paper},
        eprint = {2410.02073},
        archivePrefix = {arXiv}
      }
      ```
    MARKDOWN
    git("-C", @source, "add", "CITATION.bib", "README.md")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Add citations")

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    resources = @project.reload.brief.fetch("resources")
    citation = resources.fetch("bibtex")
    assert_equal "CITATION.bib", citation.fetch("path")
    assert_equal "CITATION.bib", @project.citation_file_name
    assert_equal File.read(File.join(@source, "CITATION.bib")), @project.citation_file
    assert_equal "10.1234/example", citation.fetch("entries").sole.fetch("doi")
    readme = resources.fetch("readme_bibtex")
    assert_equal "README.md", readme.fetch("path")
    assert_equal "parsed", readme.fetch("parse_status")
    entry = readme.fetch("entries").sole
    assert_equal "A model paper", entry.fetch("title")
    assert_equal "2410.02073", entry.fetch("eprint")
    assert_equal 6, entry.fetch("line")
    assert_equal "Smith", entry.fetch("authors").sole.fetch("family_names")
    assert_includes readme.fetch("diagnostics").map { |diagnostic| diagnostic.fetch("code") }, "missing_comma"
    assert_equal 1, clone_commands.size
    assert_empty @project.project_papers
  end

  test "GitHub scans authenticate through Git without storing the token" do
    ENV["GITHUB_TOKEN"] = "github-test-token"
    @project.update!(repository: { "clone_url" => @project.url })
    github_git

    RepositoryScanWorker.new.perform(@project.id)

    assert_equal "authenticated", File.read(File.join(@directory, "credentials-checked"))
    assert @project.reload.brief.key?("dependencies")
    assert_equal "success", @project.swhids["status"]
    assert_equal "swh:1:rev:#{@commit}", @project.swhids.dig("revision", "swhid")
    refute_includes @project.swhids.to_json, ENV["GITHUB_TOKEN"]
    refute_includes @project.brief.to_json, ENV["GITHUB_TOKEN"]
    refute_includes File.read(@trace), ENV["GITHUB_TOKEN"]
    assert clone_commands.first.include?("credential.helper=")
  end

  test "version rescan task refreshes an older scan through a real checkout and skips it afterwards" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:rescan_brief")
    readme = "# Example\n```bibtex\n@article{example, title={Example paper}, year={2026}}\n```\n"
    File.write(File.join(@source, "README.md"), readme)
    git("-C", @source, "add", "README.md")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Add README citation")
    original = { "status" => "success", "origin_archive" => { "status" => "archived" } }
    @project.update!(brief: { "version" => "0.14.0", "dependencies" => [] }, readme: readme, swhids: original)
    previous_limit = ENV["LIMIT"]
    ENV["LIMIT"] = "100"

    output, = capture_io { Rake::Task["projects:rescan_brief"].execute }
    assert_equal 1, JSON.parse(output).fetch("enqueued")
    RepositoryScanWorker.perform_one

    @project.reload
    assert_equal "Example paper", @project.brief.dig("resources", "readme_bibtex", "entries").sole.fetch("title")
    assert_equal BriefRescanEnqueuer.current_version.to_s, @project.brief.fetch("version")
    assert_equal original, @project.swhids
    assert_equal 1, clone_commands.size
    assert_not File.exist?(clone_commands.first.last)
    assert_empty @project.project_papers
    output, = capture_io { Rake::Task["projects:rescan_brief"].execute }
    assert_equal 0, JSON.parse(output).fetch("selected")
  ensure
    previous_limit ? ENV["LIMIT"] = previous_limit : ENV.delete("LIMIT")
  end

  test "a failed version rescan keeps the previous successful scan and its score" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:rescan_brief")
    RepositoryScanWorker.new.perform(@project.id)
    @project.reload
    assert @project.science_score_breakdown.dig("breakdown", "has_research_tooling", "present")
    successful = @project.brief.merge("version" => "0.14.0")
    score = @project.science_score
    @project.update_columns(brief: successful,
      repository: @project.repository.merge("clone_url" => File.join(@directory, "missing")))
    previous_limit = ENV["LIMIT"]
    ENV["LIMIT"] = "100"

    output, = capture_io { Rake::Task["projects:rescan_brief"].execute }
    assert_equal 1, JSON.parse(output).fetch("enqueued")
    RepositoryScanWorker.perform_one

    @project.reload
    assert_equal successful, @project.brief.except("last_error")
    assert_match "does not exist", @project.brief.dig("last_error", "error")
    @project.update_science_score
    assert_equal score, @project.reload.science_score
    assert @project.science_score_breakdown.dig("breakdown", "has_research_tooling", "present")
    SoftwareSearchIndexer.index(@project.id)
    assert_not_empty @project.reload.search_identifiers
    output, = capture_io { Rake::Task["projects:rescan_brief"].execute }
    assert_equal 0, JSON.parse(output).fetch("selected")
  ensure
    previous_limit ? ENV["LIMIT"] = previous_limit : ENV.delete("LIMIT")
  end

  test "failed first scans are retried after a growing cooldown until the retry limit" do
    @project.update!(repository: { "clone_url" => File.join(@directory, "missing") })
    scan = -> { BriefScanEnqueuer.new(limit: 10).enqueue.tap { RepositoryScanWorker.drain } }

    assert_equal 1, scan.call
    assert_equal 1, @project.reload.brief["attempts"]
    assert_equal 0, scan.call
    travel 8.days
    assert_equal 1, scan.call
    assert_equal 2, @project.reload.brief["attempts"]
    travel 8.days
    assert_equal 0, scan.call
    travel 7.days
    assert_equal 1, scan.call
    assert_equal 3, @project.reload.brief["attempts"]
    travel 365.days
    assert_equal 0, scan.call
    assert_not @project.reload.brief_scan_due?
  end

  test "a retried first scan replaces the stored failure with evidence" do
    @project.update_columns(brief: { "error" => "fatal: expected flush after ref listing", "attempted_at" => 8.days.ago.iso8601, "attempts" => 1 })

    assert_equal 1, BriefScanEnqueuer.new(limit: 10).enqueue
    RepositoryScanWorker.drain

    @project.reload
    assert @project.brief.key?("dependencies")
    assert_not @project.brief.key?("error")
    assert @project.science_score_breakdown.dig("breakdown", "has_research_tooling", "present")
    assert_equal 0, BriefScanEnqueuer.new(limit: 10).enqueue
  end

  test "repositories over the disk limit are scanned without large files or SWHIDs" do
    File.binwrite(File.join(@source, "measurements.bin"), Random.bytes(4.megabytes))
    git("-C", @source, "add", ".")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Add data")
    git("-C", @source, "config", "uploadpack.allowFilter", "true")
    origin = "file://#{@source}"
    @project.update!(repository: { "clone_url" => origin })
    full = RepositoryCheckout.new(origin, disk_limit: 3.megabytes)
    partial = RepositoryCheckout.new(origin, disk_limit: 3.megabytes, partial: true)
    RepositoryCheckout.expects(:new).with(origin, revision: nil, skip_lfs: false).returns(full)
    RepositoryCheckout.expects(:new).with(origin, revision: nil, skip_lfs: false, partial: true).returns(partial)

    RepositoryScanWorker.new.perform(@project.id)

    @project.reload
    assert @project.brief.key?("dependencies")
    assert_not @project.brief.key?("error")
    assert_equal({ "blob_limit" => 1.megabyte, "skipped_paths" => 1 }, @project.brief["partial_checkout"])
    assert @project.science_score_breakdown.dig("breakdown", "has_research_tooling", "present")
    assert_equal "error", @project.swhids["status"]
    assert_equal RepositoryCheckout::DISK_LIMIT_ERROR, @project.swhids["error"]
  end

  test "a stored disk limit failure retries with a partial checkout directly" do
    origin = "file://#{@source}"
    git("-C", @source, "config", "uploadpack.allowFilter", "true")
    @project.update!(repository: { "clone_url" => origin })
    @project.update_columns(brief: { "error" => RepositoryCheckout::DISK_LIMIT_ERROR, "attempted_at" => 30.days.ago.iso8601 })
    partial = RepositoryCheckout.new(origin, partial: true)
    RepositoryCheckout.expects(:new).once.with(origin, revision: nil, skip_lfs: false, partial: true).returns(partial)

    assert_equal 1, BriefScanEnqueuer.new(limit: 10).enqueue
    RepositoryScanWorker.drain

    assert @project.reload.brief.key?("dependencies")
    assert_equal 0, @project.brief.dig("partial_checkout", "skipped_paths")
  end

  test "repositories too large for a partial checkout are recorded and not retried" do
    origin = "file://#{@source}"
    git("-C", @source, "config", "uploadpack.allowFilter", "true")
    @project.update!(repository: { "clone_url" => origin })
    full = RepositoryCheckout.new(origin, disk_limit: 1)
    partial = RepositoryCheckout.new(origin, disk_limit: 1, partial: true)
    RepositoryCheckout.expects(:new).twice.returns(full).then.returns(partial)

    RepositoryScanWorker.new.perform(@project.id)

    assert_equal Project::BRIEF_TOO_LARGE_ERROR, @project.reload.brief["error"]
    travel 365.days
    assert_not @project.brief_scan_due?
    assert_equal 0, BriefScanEnqueuer.new(limit: 10).enqueue
  end

  test "project syncs queue first scans for registry matches but leave retries to the capped task" do
    @project.update!(science_score: 0, joss_metadata: nil)
    record = ExternalSoftwareRecord.create!(source: "ascl", identifier: "ascl:2601.001", status: "ok", retrieved_at: Time.current, next_refresh_at: Time.current)
    ProjectExternalSoftwareRecord.create!(project: @project, external_software_record: record, relationship: "repository", match_status: "matched")
    @project.update_columns(brief: { "error" => "timeout", "attempted_at" => 30.days.ago.iso8601, "attempts" => 1 })

    assert @project.brief_scan_due?
    assert_nil @project.fetch_swhids_async
    assert_empty RepositoryScanWorker.jobs
    assert_equal 1, BriefScanEnqueuer.new(limit: 1).enqueue

    unscanned = Project.create!(url: "https://github.com/test/unscanned", science_score: 0, repository: { "clone_url" => @source })
    ProjectExternalSoftwareRecord.create!(project: unscanned, external_software_record: record, relationship: "repository", match_status: "matched")
    assert unscanned.fetch_swhids_async
    assert_equal [@project.id, unscanned.id], RepositoryScanWorker.jobs.map { |job| job["args"].first }
  end

  test "first scans are selected ahead of due retries" do
    @project.update_columns(brief: { "error" => "timeout", "attempted_at" => 30.days.ago.iso8601, "attempts" => 1 })
    unscanned = Project.create!(url: "https://github.com/test/unscanned", science_score: 50, repository: { "clone_url" => @source })

    assert_equal 1, BriefScanEnqueuer.new(limit: 1).enqueue
    assert_equal [[unscanned.id]], RepositoryScanWorker.jobs.map { |job| job["args"] }
    BriefScanEnqueuer.new(limit: 2).enqueue
    assert_equal [unscanned.id, @project.id], RepositoryScanWorker.jobs.map { |job| job["args"].first }
  end

  test "a configured GitHub token does not add credentials to local clones" do
    ENV["GITHUB_TOKEN"] = "github-test-token"

    RepositoryScanWorker.new.perform(@project.id)

    assert_equal "success", @project.reload.swhids["status"]
    assert_equal ["credential.helper="], clone_commands.first.grep(/\Acredential.helper=/)
  end

  test "Brief can promote a project and calculate SWHIDs using the same checkout" do
    @project.update!(science_score: 1, joss_metadata: nil)

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_operator @project.reload.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
    assert_equal "success", @project.swhids["status"]
    assert_equal 1, clone_commands.size
  end

  test "a scan collects detected CFF metadata and credits the citation content" do
    content = "cff-version: 1.2.0\nmessage: Please cite this software\ntitle: Research software\nauthors:\n  - family-names: Smith\n"
    File.write(File.join(@source, "CITATION.cff"), content)
    git("-C", @source, "add", "CITATION.cff")
    git("-C", @source, "-c", "user.name=Test", "-c", "user.email=test@example.org",
      "-c", "commit.gpgsign=false", "commit", "-m", "Add citation file")
    @project.update!(science_score: 1, joss_metadata: nil,
      repository: { "clone_url" => @source, "metadata" => { "files" => { "citation" => "CITATION.cff" } } })

    RepositoryScanWorker.new.perform(@project.id)

    @project.reload
    assert @project.brief.key?("dependencies")
    assert_equal content, @project.citation_file
    assert @project.science_score_breakdown.dig(:breakdown, :has_citation_file, :present)
    assert_equal 1.0, @project.science_score_breakdown.dig(:breakdown, :has_citation_file, :strength)
    assert_operator @project.science_score, :>=, 36.0
  end

  test "a zero-score Wikidata match is queued scanned and scored through one checkout" do
    @project.update!(science_score: 0, joss_metadata: nil)
    record = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q123", status: "ok", retrieved_at: Time.current, next_refresh_at: Time.current)
    ProjectExternalSoftwareRecord.create!(project: @project, external_software_record: record, relationship: "repository", match_status: "matched")

    assert_equal 1, BriefScanEnqueuer.new(limit: 1).enqueue
    RepositoryScanWorker.perform_one

    assert_operator @project.reload.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
    assert @project.brief.fetch("languages").any? { |language| language["name"] == "Fortran" }
    assert_equal "success", @project.swhids["status"]
    assert_equal 1, clone_commands.size
  end

  test "Brief runs without replacing stored SWHIDs or archival evidence" do
    original = { "status" => "success", "origin_archive" => { "status" => "archived" },
      "archival" => { "id" => 123, "status" => "completed" } }
    @project.update!(swhids: original)
    SwhidCalculator.any_instance.expects(:calculate).never

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_equal original, @project.reload.swhids
    assert @project.brief.key?("dependencies")
    assert_equal 1, clone_commands.size
  end

  test "rescan refreshes completed Brief data and scores without replacing existing SWHIDs" do
    original = { "status" => "success", "origin_archive" => { "status" => "archived" } }
    @project.update!(science_score: 0, joss_metadata: nil, brief: { "dependencies" => [] }, swhids: original)
    link_identifier

    assert_equal 1, BriefScanEnqueuer.new(limit: 1, rescan: true).enqueue
    Project.expects(:eligible_for_brief).never
    Project.expects(:with_external_identifier).never
    Package.expects(:direct_scientific_dependencies).never
    RepositoryScanWorker.perform_one

    assert @project.reload.brief.fetch("languages").any? { |language| language["name"] == "Fortran" }
    assert_operator @project.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
    assert_equal original, @project.swhids
    assert_equal 1, clone_commands.size
  end

  test "rescan retries a stored Brief error" do
    @project.update!(science_score: 0, joss_metadata: nil, brief: { "error" => "timeout" })
    link_identifier

    RepositoryScanWorker.perform_async(@project.id, true)
    RepositoryScanWorker.perform_one

    refute @project.reload.brief.key?("error")
    assert @project.brief.key?("dependencies")
    assert_operator @project.science_score, :>=, Project::SCIENCE_SCORE_THRESHOLD
  end

  test "rescan rechecks the score and identifier after enqueueing" do
    @project.update!(science_score: 0, joss_metadata: nil, brief: { "dependencies" => [] })
    link = link_identifier
    RepositoryScanWorker.perform_async(@project.id, true)
    @project.update!(science_score: Project::SCIENCE_SCORE_THRESHOLD)
    RepositoryScanWorker.perform_one
    assert_empty clone_commands

    @project.update!(science_score: 0)
    RepositoryScanWorker.perform_async(@project.id, true)
    link.update!(match_status: "ambiguous")
    RepositoryScanWorker.perform_one
    assert_empty clone_commands
  end

  def link_identifier
    record = ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q456", status: "ok", retrieved_at: Time.current, next_refresh_at: Time.current)
    ProjectExternalSoftwareRecord.create!(project: @project, external_software_record: record, relationship: "repository", match_status: "matched")
  end

  test "a Brief command failure preserves successful SWHIDs and removes the checkout" do
    failing_binary("brief")

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_match "analysis failed", @project.reload.brief["error"]
    assert_equal "success", @project.swhids["status"]
    assert_equal 1, clone_commands.size
    assert_not File.exist?(@project.swhids.dig("directory", "input", "path"))
  end

  test "a SWHID command failure still saves Brief results" do
    failing_binary("swhid")

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one

    assert_equal "error", @project.reload.swhids["status"]
    assert @project.brief.key?("dependencies")
    assert_equal 1, clone_commands.size
    assert_not File.exist?(clone_commands.first.last)
  end

  test "clone failures are recorded for both due analyses without replacing origin coverage" do
    coverage = { "status" => "archived", "checked_at" => Time.current.iso8601 }
    @project.update!(repository: { "clone_url" => File.join(@directory, "missing") },
      swhids: { "origin_archive" => coverage })

    RepositoryScanWorker.perform_async(@project.id)
    RepositoryScanWorker.perform_one
    RepositoryScanWorker.new.perform(@project.id)

    assert_match "does not exist", @project.reload.brief["error"]
    assert_equal "error", @project.swhids["status"]
    assert_equal coverage, @project.swhids["origin_archive"]
    assert_equal 1, clone_commands.size
    assert_not File.exist?(clone_commands.first.last)
  end

  test "a project lock prevents legacy and new workers from overlapping scans" do
    options = Project.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password)
    connection = PG.connect(options)
    assert_equal Project.connection.current_database, connection.db
    key = "#{RepositoryScanWorker::LOCK_NAMESPACE}, #{@project.id}"
    connection.exec("SELECT pg_advisory_lock(#{key})")

    FetchBriefWorker.new.perform(@project.id)
    FetchSwhidWorker.new.perform(@project.id)
    RepositoryScanWorker.new.perform(@project.id)

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_nil @project.swhids
    connection.exec("SELECT pg_advisory_unlock(#{key})")
    RepositoryScanWorker.new.perform(@project.id)
    assert_equal "success", @project.reload.swhids["status"]
  ensure
    connection&.close
  end

  test "API retries use stored identifiers without cloning or running Brief" do
    @project.update!(swhids: { "status" => "success", "revision" => {
      "status" => "success", "swhid" => "swh:1:rev:#{@commit}" } })

    CheckSwhidWorker.perform_async(@project.id)
    CheckSwhidWorker.perform_one

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_equal "swh_api", CheckSwhidWorker.get_sidekiq_options["queue"]
  end

  test "projects below both selection thresholds are not cloned" do
    @project.update!(science_score: 0, joss_metadata: nil)

    RepositoryScanWorker.new.perform(@project.id)

    assert_empty clone_commands
    assert_nil @project.reload.brief
    assert_nil @project.swhids
  end

  def failing_binary(name)
    directory = File.join(@directory, "bin")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, name)
    File.write(path, "#!/bin/sh\necho 'analysis failed' >&2\nexit 1\n")
    File.chmod(0755, path)
    ENV["PATH"] = "#{directory}:#{@previous_path}"
  end

  def github_git
    real_git = Open3.capture3("which", "git").first.strip
    directory = File.join(@directory, "bin")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "git")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "open3"
      args = ARGV.dup
      if position = args.index("clone")
        output, _, status = Open3.capture3(#{real_git.inspect}, *args.take(position), "credential", "fill", stdin_data: "protocol=https\\nhost=github.com\\n\\n")
        abort "GitHub credentials unavailable" unless status.success? && output.lines.include?("password=" + ENV.fetch("GITHUB_TOKEN") + "\\n")
        File.write(#{File.join(@directory, 'credentials-checked').inspect}, "authenticated")
        args[-2] = #{@source.inspect}
      end
      exec #{real_git.inspect}, *args
    RUBY
    File.chmod(0755, path)
    ENV["PATH"] = "#{directory}:#{@previous_path}"
  end

  def clone_commands
    return [] unless File.exist?(@trace)

    File.readlines(@trace).map { |line| JSON.parse(line) }
      .select { |event| event["event"] == "start" && event["argv"]&.include?("clone") }
      .map { |event| event.fetch("argv") }
  end

  def git(*args)
    output, error, status = Open3.capture3("git", *args)
    assert status.success?, error
    output
  end
end
