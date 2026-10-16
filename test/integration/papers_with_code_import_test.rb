require "test_helper"
require "tmpdir"

class PapersWithCodeImportTest < ActionDispatch::IntegrationTest
  setup do
    @directory = Dir.mktmpdir("pwc")
    @file = File.join(@directory, "links.jsonl")
    @snapshot = "56cc5c1938678c33dedebf5f74fc4e62e2c35381"
    @project = Project.create!(url: "https://github.com/leongeiger/kerr")
    @row = {
      "paper_url" => "https://paperswithcode.com/paper/odyssey-a-public-gpu-based-code-for-general",
      "paper_title" => "Odyssey: A Public GPU-Based Code for General-Relativistic Radiative Transfer in Kerr Spacetime",
      "paper_arxiv_id" => "1601.02063", "paper_url_abs" => "https://arxiv.org/abs/1601.02063v2",
      "paper_url_pdf" => "https://arxiv.org/pdf/1601.02063v2.pdf", "repo_url" => "https://github.com/LeonGeiger/Kerr",
      "is_official" => false, "mentioned_in_paper" => false, "mentioned_in_github" => true, "framework" => "none"
    }
    @run = 0
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  def run_import(rows, apply: true, limit: nil)
    File.write(@file, rows.map(&:to_json).join("\n") + "\n")
    @options = { file: @file, sha256: Digest::SHA256.file(@file).hexdigest,
      output: File.join(@directory, "result-#{@run += 1}.jsonl"), snapshot: @snapshot, apply: apply, limit: limit }
    report = PapersWithCodeImporter.new.call(**@options)
    [report, File.readlines(@options[:output]).map { |line| JSON.parse(line) }]
  end

  test "plans without writes and imports a historical association visible through the website" do
    assert_no_difference ["Paper.count", "ProjectPaper.count", "PaperIdentifier.count", "Project.count"] do
      summary, ledger = run_import([@row], apply: false)
      assert_equal 1, summary.dig("counts", "would_create")
      assert_equal @row, ledger.sole["record"]
      assert_equal false, ledger.sole["applied"]
    end
    assert_difference "Paper.count", 1 do
      assert_difference "ProjectPaper.count", 1 do
        assert_no_difference "Project.count" do
          summary, = run_import([@row])
          assert_equal 1, summary.dig("counts", "created")
        end
      end
    end
    link = @project.project_papers.sole
    assert_equal "reference", link.role
    assert_equal "1601.02063", link.paper.paper_identifiers.sole.identifier
    assert_equal @row, link.evidence.sole["record"]
    assert_equal PapersWithCodeImporter::LICENSE, link.evidence.sole["license"]
    get project_path(@project)
    assert_response :success
    assert_select "[data-related-paper-id='#{link.paper_id}']"
    assert_includes response.body, "Papers with code"
  end

  test "replay preserves metadata roles independent evidence and timestamps across input files" do
    paper = Paper.create!(title: "Existing title", urls: ["http://export.arxiv.org/pdf/1601.02063v1.pdf"])
    evidence = { "source" => "reviewed_repository", "url" => @project.url }
    link = ProjectPaper.create!(project: @project, paper: paper, role: "software_description", evidence: [evidence])
    assert_no_difference "Paper.count" do
      run_import([@row.merge("is_official" => true), @row])
    end
    assert_equal "Existing title", paper.reload.title
    assert_equal "software_description", link.reload.role
    assert_includes link.evidence, evidence
    assert_equal 3, link.evidence.size
    before = [link.attributes, paper.attributes, paper.paper_identifiers.sole.attributes]
    summary, = run_import([@row])
    assert_equal 1, summary.dig("counts", "unchanged")
    assert_equal before, [link.reload.attributes, paper.reload.attributes, paper.paper_identifiers.sole.attributes]
  end

  test "aliases match one project and ambiguous aliases remain unresolved" do
    alias_url = "https://github.com/old/kerr"
    ProjectRepositoryAlias.create!(project: @project, url: alias_url)
    _, rows = run_import([@row.merge("repo_url" => "#{alias_url}.git/tree/main")])
    assert_equal "created", rows.sole["status"]
    assert_equal ["repository_alias"], rows.sole["repository_match_sources"]
    other = Project.create!(url: "https://github.com/another/kerr")
    ProjectRepositoryAlias.create!(project: other, url: alias_url)
    assert_no_difference "ProjectPaper.count" do
      _, rows = run_import([@row.merge("repo_url" => alias_url)])
      assert_equal "repository_ambiguous", rows.sole["status"]
    end
  end

  test "does not choose between duplicate paper records or conflicting archive IDs" do
    Paper.create!(title: "First", urls: [@row["paper_url_abs"]])
    Paper.create!(title: "Second", doi: "https://doi.org/10.48550/arXiv.1601.02063")
    assert_no_difference ["PaperIdentifier.count", "ProjectPaper.count", "Paper.count"] do
      _, rows = run_import([@row, @row.merge("paper_arxiv_id" => "1701.00001")])
      assert_equal %w[paper_ambiguous paper_identifier_conflict], rows.map { |r| r["status"] }
    end
  end

  test "keeps unsupported missing and invalid rows without creating projects or papers" do
    rows = [@row.merge("repo_url" => "https://example.com/unknown/project"),
      @row.merge("paper_arxiv_id" => nil, "paper_url_abs" => "https://example.com/paper", "paper_url_pdf" => nil),
      @row.merge("paper_arxiv_id" => "not-an-id"), @row.merge("is_official" => "true"),
      @row.merge("repo_url" => "https://github.com/owner")]
    assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count"] do
      _, ledger = run_import(rows)
      assert_equal %w[repository_unsupported paper_unresolved invalid_arxiv invalid_flags invalid_repository], ledger.map { |r| r["status"] }
      assert_equal rows, ledger.map { |r| r["record"] }
    end
  end

  test "deduplicates repeated rows and links an exact existing DOI without title matching" do
    paper = Paper.create!(title: "Stored title", doi: "10.1234/exact")
    row = @row.merge("paper_arxiv_id" => nil, "paper_url_abs" => "https://doi.org/10.1234/EXACT", "paper_url_pdf" => nil)
    assert_no_difference "Paper.count" do
      summary, = run_import([row, row])
      assert_equal 1, summary.dig("counts", "created")
      assert_equal 1, summary.dig("counts", "duplicate_record")
    end
    assert_equal paper, @project.project_papers.sole.paper
  end

  test "later OpenAlex enrichment merges into the imported arxiv identity" do
    run_import([@row])
    paper = @project.project_papers.sole.paper
    assert_no_difference "Paper.count" do
      Paper.import_openalex!("id" => "https://openalex.org/W12345", "title" => "Published title",
        "doi" => "https://doi.org/10.1234/published", "locations" => [{ "landing_page_url" => @row["paper_url_abs"] }])
    end
    assert_equal "https://openalex.org/W12345", paper.reload.openalex_id
    assert_equal "10.1234/published", paper.doi
    assert_equal "reference", @project.project_papers.sole.role
  end

  test "checksum mismatch and existing output fail before database changes" do
    run_import([@row], apply: false)
    assert_no_difference ["Paper.count", "ProjectPaper.count"] do
      assert_raises(ArgumentError) { PapersWithCodeImporter.new.call(**@options.merge(sha256: "0" * 64)) }
      assert_raises(Errno::EEXIST) { PapersWithCodeImporter.new.call(**@options) }
    end
  end

  test "console trial limits writes while verifying the complete archive and reports progress" do
    rows = [@row, @row.merge("is_official" => true)]
    File.write(@file, rows.map(&:to_json).join("\n") + "\n")
    options = { file: @file, output: File.join(@directory, "console.jsonl"),
      snapshot: @snapshot, sha256: Digest::SHA256.file(@file).hexdigest,
      apply: true, limit: 1 }
    progress = []
    assert_difference "ProjectPaper.count", 1 do
      result = PapersWithCodeImporter.new.call(**options) { |status| progress << status }
      assert_equal 1, result["processed"]
      assert_equal 1, result["limit"]
      assert_equal [result], progress
      assert_equal({ "created" => 1, "new_papers" => 1 }, result["counts"])
    end
    assert_equal [@row], @project.project_papers.sole.evidence.map { |evidence| evidence["record"] }
    ledger = File.readlines(options[:output]).map { |line| JSON.parse(line) }
    assert_equal [1], ledger.map { |row| row["line"] }
    File.open(options[:file], "a") { |file| file.puts @row.to_json }
    assert_raises(ArgumentError) do
      PapersWithCodeImporter.new.call(**options.merge(output: File.join(@directory, "changed.jsonl")))
    end
  end

  test "console import can replay committed batches after interruption" do
    rows = 101.times.map do |i|
      id = "1601.#{format('%05d', i + 1)}"
      @row.merge("paper_arxiv_id" => id, "paper_url_abs" => "https://arxiv.org/abs/#{id}",
        "paper_url_pdf" => "https://arxiv.org/pdf/#{id}", "paper_url" => "https://paperswithcode.com/paper/paper-#{id}")
    end
    File.write(@file, rows.map(&:to_json).join("\n") + "\n")
    options = { file: @file, output: File.join(@directory, "interrupted.jsonl"),
      snapshot: @snapshot, sha256: Digest::SHA256.file(@file).hexdigest, apply: true }
    assert_difference "ProjectPaper.count", 100 do
      assert_raises(Interrupt) do
        PapersWithCodeImporter.new.call(**options) do |status|
          assert_equal 100, status["processed"]
          assert_equal 100, File.readlines(options[:output]).size
          raise Interrupt
        end
      end
    end
    before = @project.project_papers.order(:id).map(&:attributes)
    progress = []
    assert_difference "ProjectPaper.count", 1 do
      result = PapersWithCodeImporter.new.call(**options.merge(output: File.join(@directory, "replayed.jsonl"))) { |status| progress << status }
      assert_equal 100, result.dig("counts", "unchanged")
      assert_equal 1, result.dig("counts", "created")
      assert_equal [100, 101], progress.map { |status| status["processed"] }
      assert_equal 0, progress.first["counts"]["created"]
    end
    assert_equal before, @project.project_papers.where(id: before.map { |row| row["id"] }).order(:id).map(&:attributes)
  end

  test "console supports a bounded preview and rejects invalid limits and apply values" do
    assert_no_difference ["ProjectPaper.count", "Paper.count"] do
      summary, ledger = run_import([@row, @row.merge("is_official" => true)], apply: false, limit: 1)
      assert_equal 1, summary["processed"]
      assert_equal 1, ledger.size
      [0, -1, "100", 1.5].each do |limit|
        assert_raises(ArgumentError) { run_import([@row], limit: limit) }
      end
      assert_raises(ArgumentError) { run_import([@row], apply: "false") }
    end
  end

  test "discovers a missing project and requests sync once across normalized URLs and replay" do
    rows = [@row.merge("repo_url" => "https://github.com/NewLab/Kerr.git/tree/main"),
      @row.merge("repo_url" => "https://github.com/newlab/kerr", "is_official" => true)]
    assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"] do
      summary, ledger = run_import(rows, apply: false)
      assert_equal 1, summary.dig("counts", "new_projects")
      assert_equal 1, summary.dig("counts", "sync_requests")
      assert_equal %w[would_create would_merge_evidence], ledger.map { |row| row["status"] }
    end
    assert_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"], 1 do
      assert_no_difference ["SyncProjectWorker.jobs.size", "SyncExternalProjectWorker.jobs.size"] do
        summary, ledger = run_import(rows)
        assert_equal 1, summary.dig("counts", "new_projects")
        assert_equal 1, summary.dig("counts", "sync_requests")
        assert_equal %w[created updated], ledger.map { |row| row["status"] }
      end
    end
    project = Project.find_by!(url: "https://github.com/newlab/kerr")
    link = project.project_papers.sole
    request = ExternalProjectSync.find_by!(project_id: project.id)
    assert_equal "reference", link.role
    assert_equal rows, link.evidence.map { |evidence| evidence["record"] }
    assert_nil project.last_synced_at
    assert_nil request.completed_at
    token, requested = request.claim
    request.finish(token, requested)
    before = [project.reload.attributes, link.reload.attributes, request.reload.attributes]
    travel 2.hours do
      assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"] do
        summary, = run_import(rows)
        assert_equal 2, summary.dig("counts", "unchanged")
        assert_equal 0, summary["counts"]["sync_requests"]
      end
    end
    assert_equal before, [project.reload.attributes, link.reload.attributes, request.reload.attributes]
    assert_empty ExternalProjectSync.pending
  end

  test "discovery respects hidden projects aliases namespaces and supported repository URLs" do
    github = Host.find_or_create_by!(name: "GitHub")
    hidden_owner = Owner.create!(host: github, login: "excluded", hidden: true)
    Project.insert_all!([{ url: "https://github.com/excluded/tool", owner_id: hidden_owner.id,
      created_at: Time.current, updated_at: Time.current }])
    hidden = Project.find_by!(url: "https://github.com/excluded/tool")
    ProjectRepositoryAlias.create!(project: hidden, url: "https://github.com/former/tool")
    gitlab = Host.create!(name: "GitLab", url: "https://gitlab.com", kind: "gitlab")
    Owner.create!(host: gitlab, login: "excluded", hidden: true)
    urls = %w[https://github.com/excluded/tool https://github.com/former/tool
      https://github.com/excluded/new https://gitlab.com/excluded/subgroup/new
      https://github.com/topics/science https://example.org/lab/tool https://github.com/lab/tool:bad
      https://github.com/lab/tool]
    urls[-1] = "https://github.com:444/lab/tool"
    [false, true].each do |apply|
      assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"] do
        _, ledger = run_import(urls.map { |url| @row.merge("repo_url" => url) }, apply: apply)
        assert_equal ["repository_hidden"] * 4 + ["repository_unsupported"] * 4, ledger.map { |row| row["status"] }
      end
    end
  end

  test "discovery does not create a project for unresolved or conflicting publication identities" do
    row = @row.merge("repo_url" => "https://github.com/newlab/kerr")
    rows = [row.merge("paper_arxiv_id" => nil, "paper_url_abs" => "https://example.org/paper", "paper_url_pdf" => nil),
      row.merge("paper_arxiv_id" => "1701.00001")]
    assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"] do
      _, ledger = run_import(rows)
      assert_equal %w[paper_unresolved paper_identifier_conflict], ledger.map { |row| row["status"] }
    end
  end

  test "paper identity failure rolls back project creation and its sync request" do
    paper = Paper.create!(title: "Conflicting identifier", urls: [@row["paper_url_abs"]])
    PaperIdentifier.create!(paper: paper, source: "arxiv", identifier: "1601.99999")
    assert_no_difference ["Project.count", "Paper.count", "ProjectPaper.count", "ExternalProjectSync.count"] do
      summary, = run_import([@row.merge("repo_url" => "https://github.com/newlab/kerr")])
      assert_equal 1, summary.dig("counts", "identity_conflict")
    end
  end

  test "discovered project enters the existing sync queue and gets scored" do
    SyncExternalProjectWorker.clear
    run_import([@row.merge("repo_url" => "https://github.com/newlab/kerr")])
    project = Project.find_by!(url: "https://github.com/newlab/kerr")
    request = ExternalProjectSync.find_by!(project_id: project.id)
    repository = { full_name: "newlab/kerr", html_url: project.url, owner: "newlab",
      host: { name: "GitHub", kind: "github", url: "https://github.com" }, metadata: { files: {} }, topics: [] }
    stub_request(:get, project.url).to_return(status: 200)
    stub_request(:get, project.repos_api_url).to_return(status: 200, body: repository.to_json)
    %i[fetch_owner find_or_create_owner fetch_dependencies fetch_packages import_mentions
      fetch_readme fetch_commits fetch_events fetch_issue_stats sync_issues fetch_citation_file
      fetch_codemeta fetch_zenodo_file sync_releases update_committers update_keywords_from_contributors].each do |method|
      Project.any_instance.stubs(method)
    end
    assert_equal 1, ExternalProjectSync.enqueue_pending(limit: 1)
    SyncExternalProjectWorker.perform_one
    assert_equal "newlab/kerr", project.reload.repository["full_name"]
    assert project.last_synced_at > 1.minute.ago
    assert_operator project.science_score, :>=, 20
    assert project.science_score_breakdown.dig(:breakdown, :has_resolved_paper, :present)
    assert_equal request.requested_at, request.reload.completed_at
  ensure
    SyncExternalProjectWorker.clear
  end

end
