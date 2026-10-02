require "test_helper"
require "rake"
require_relative "../support/biotools_pipeline"
require_relative "../support/wikidata_pipeline"

class DiscoverExternalRepositoriesWorkerTest < ActiveSupport::TestCase
  include BiotoolsPipeline
  include WikidataPipeline

  setup do
    clear_discovery_jobs
    Rails.application.load_tasks unless Rake::Task.task_defined?("external_software:discover")
  end
  teardown { clear_discovery_jobs }

  def clear_discovery_jobs
    [DiscoverExternalRepositoriesWorker, SyncExternalProjectWorker].each do |worker|
      worker.clear
      SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{worker.get_sidekiq_options.fetch('lock_prefix')}:*")
    end
    SyncProjectWorker.clear
  end

  def import_biotools(id = "scanpy", urls: nil)
    payload = @biotools.fetch(id).deep_dup
    payload["link"] = urls.map { |url| { "url" => url, "type" => ["Repository"] } } if urls
    biotools_record(id, payload: payload)
    SyncBiotoolsWorker.new.perform([id])
    ExternalSoftwareRecord.find_by!(source: "biotools", identifier: id)
  end

  def discover(limit = 100)
    DiscoverExternalRepositoriesWorker.perform_async(limit)
    DiscoverExternalRepositoriesWorker.perform_one
  end

  test "scheduled task discovers unlabelled repositories and retains provenance without awarding scores" do
    payload = JSON.parse(Rails.root.join("test/fixtures/files/wikidata.json").read)
    entity = payload.fetch("entities").fetch("Q5971368")
    entity["claims"] = entity["claims"].slice("P1324")
    entity.delete("labels")
    stub_request(:get, WikidataClient::API_URL)
      .with(query: { action: "wbgetentities", ids: "Q5971368", format: "json", maxlag: 5 })
      .to_return(body: { entities: { Q5971368: entity } }.to_json)
    SyncWikidataWorker.new.perform(["Q5971368"])
    bio = import_biotools(urls: ["http://github.com/SymPy/SymPy.git", "https://github.com/sympy/sympy/"])
    assert_equal 0, Project.count
    ENV["LIMIT"] = "2"
    Rake::Task["external_software:discover"].reenable
    capture_io { Rake::Task["external_software:discover"].invoke }
    assert_difference "Project.count", 1 do
      DiscoverExternalRepositoriesWorker.perform_one
    end
    project = Project.sole
    assert_equal "https://github.com/sympy/sympy", project.url
    assert_equal 0, project.science_score.to_f
    assert_nil project.last_synced_at
    assert_equal 2, project.external_software_records.count
    assert_equal 2, bio.project_external_software_records.sole.evidence.size
    assert_equal 1, ExternalProjectSync.pending.count
    assert_equal 1, SyncExternalProjectWorker.jobs.size
    assert ExternalSoftwareRecord.all.all?(&:discovered_at)
    assert_empty ExternalRepositoryDiscovery.due
    before = ExternalProjectSync.sole.requested_at
    discover
    assert_equal before, ExternalProjectSync.sole.reload.requested_at
    assert_equal 1, SyncExternalProjectWorker.jobs.size
    assert_equal 1, Project.count
  ensure
    ENV.delete("LIMIT")
  end

  test "aliases and case insensitive current URLs prevent duplicate projects" do
    project = Project.create!(url: "https://github.com/ScVerse/ScanPy", science_score: 42, last_synced_at: 1.day.ago)
    project.repository_aliases.create!(url: "https://github.com/theislab/scanpy")
    record = import_biotools(urls: ["https://github.com/theislab/scanpy.git", project.url.downcase])
    assert_no_difference "Project.count" do
      discover
    end
    assert_equal [project.id], record.projects.pluck(:id)
    assert_equal %w[existing existing], record.reload.discovery_result["repositories"].pluck("status")
    assert_empty ExternalProjectSync.all
    assert_equal 42, project.reload.science_score
  end

  test "ambiguous aliases retain both matches and do not enqueue enrichment" do
    projects = %w[first second].map { |name| Project.create!(url: "https://github.com/#{name}/scanpy", science_score: 0) }
    projects.each { |project| project.repository_aliases.create!(url: "https://github.com/theislab/scanpy") }
    record = import_biotools
    discover
    assert_equal 2, Project.count
    assert_equal ["ambiguous"], record.project_external_software_records.distinct.pluck(:match_status)
    assert_equal "ambiguous", record.reload.discovery_result["repositories"].sole["status"]
    assert_empty ExternalProjectSync.all
  end

  test "hidden owners and hidden project aliases cannot be recreated" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "github")
    owner = host.owners.create!(login: "blocked", hidden: false)
    project = Project.create!(url: "https://github.com/blocked/scanpy", owner_record: owner)
    project.repository_aliases.create!(url: "https://github.com/former/scanpy")
    owner.update!(hidden: true)
    record = import_biotools(urls: [project.url, "https://github.com/former/scanpy", "https://github.com/BLOCKED/new-tool"])
    assert_no_difference "Project.count" do
      discover
    end
    assert_equal ["hidden"], record.reload.discovery_result["repositories"].pluck("status").uniq
    assert_empty ExternalProjectSync.all
    assert_empty record.project_external_software_records
  end

  test "resolved ambiguity requests enrichment without needing a source metadata change" do
    projects = %w[first second].map { |name| Project.create!(url: "https://github.com/#{name}/scanpy", science_score: 0) }
    projects.each { |project| project.repository_aliases.create!(url: "https://github.com/theislab/scanpy") }
    record = import_biotools
    discover
    assert_empty ExternalProjectSync.all
    projects.last.repository_aliases.delete_all
    travel 31.days do
      discover
    end
    assert_equal [projects.first.id], ExternalProjectSync.pending.pluck(:project_id)
    assert_equal "existing", record.reload.discovery_result["repositories"].sole["status"]
    assert_equal "matched", record.project_external_software_records.sole.match_status
  end

  test "nested hidden GitLab namespaces and nonstandard ports are not imported" do
    host = Host.create!(name: "gitlab.institute.edu", url: "https://gitlab.institute.edu", kind: "GitLab")
    host.owners.create!(login: "lab/team", hidden: true)
    record = import_biotools(urls: ["https://gitlab.institute.edu/lab/team/software",
      "https://github.com:8080/lab/software"])
    discover
    assert_empty Project.all
    assert_equal %w[hidden unsupported], record.reload.discovery_result["repositories"].pluck("status")
  end

  test "known GitLab hosts preserve nested namespaces and other hosts remain unresolved" do
    Host.create!(name: "gitlab.institute.edu", url: "https://gitlab.institute.edu", kind: "GitLab")
    urls = ["https://gitlab.institute.edu/lab/team/software/-/tree/main",
      "https://gitlab.com/collective/group/tool.git", "https://unknown.example/lab/software",
      "https://github.com/topics/science", "https://github.com/lab/../secret",
      "https://user:secret@github.com/lab/software"]
    record = import_biotools(urls: urls)
    discover
    assert_equal ["https://gitlab.com/collective/group/tool", "https://gitlab.institute.edu/lab/team/software"], Project.order(:url).pluck(:url)
    assert_equal 2, ExternalProjectSync.count
    statuses = record.reload.discovery_result["repositories"].pluck("status").tally
    assert_equal({ "created" => 2, "unsupported" => 3 }, statuses)
  end

  test "new evidence requeues zero score projects but unchanged source refreshes do not" do
    project = Project.create!(url: "https://github.com/theislab/scanpy", science_score: 0, last_synced_at: 1.day.ago)
    record = import_biotools
    discover
    request = ExternalProjectSync.sole
    request.update!(completed_at: request.requested_at)
    clear_discovery_jobs
    record.update!(next_refresh_at: 1.minute.ago)
    import_biotools
    discover
    assert_empty ExternalProjectSync.pending
    assert_nil record.reload.next_discovery_at

    @biotools["scanpy"]["description"] = "New scientific metadata"
    record.update!(next_refresh_at: 1.minute.ago)
    import_biotools
    discover
    assert_equal [project.id], ExternalProjectSync.pending.pluck(:project_id)
    assert_equal 0, project.reload.science_score
  end

  test "timestamp-only changes and reordered source fields do not request another sync" do
    record = import_biotools
    discover
    request = ExternalProjectSync.sole
    request.update!(completed_at: request.requested_at)
    clear_discovery_jobs
    record.update!(next_refresh_at: 1.minute.ago)
    @biotools["scanpy"]["lastUpdate"] = "2026-10-03T00:00:00Z"
    @biotools["scanpy"]["link"].reverse!
    import_biotools
    discover
    assert_empty ExternalProjectSync.pending
  end

  test "bounded batches resume and missing or failed source records do not create projects" do
    records = %w[scanpy multiqc nextflow].map { |id| import_biotools(id) }
    records.last.update!(status: "missing")
    discover(1)
    assert_equal 1, Project.count
    assert_equal 1, ExternalRepositoryDiscovery.due.count
    discover(1)
    assert_equal 2, Project.count
    assert_empty ExternalRepositoryDiscovery.due
    records.last.update!(status: "error")
    discover
    assert_equal 2, Project.count
    [0, 101, "10"].each do |limit|
      assert_raises(ArgumentError) { DiscoverExternalRepositoriesWorker.new.perform(limit) }
    end
  end

  test "database failure rolls back the record and retries without partial projects or joins" do
    record = import_biotools
    ExternalSoftwareImporter.any_instance.stubs(:persist_links).raises(ActiveRecord::Deadlocked, "retry")
    result = DiscoverExternalRepositoriesWorker.new.perform(1)
    assert_equal 1, result[:failed]
    assert_equal 0, Project.count
    assert_empty ExternalProjectSync.all
    assert_empty ProjectExternalSoftwareRecord.all
    assert_match "retry", record.reload.discovery_error
    assert record.next_discovery_at > 59.minutes.from_now
    ExternalSoftwareImporter.any_instance.unstub(:persist_links)
    travel 61.minutes do
      discover
    end
    assert_equal 1, Project.count
    assert_nil record.reload.discovery_error
  end

  test "a lost queue submission leaves durable sync requests for the next task" do
    record = import_biotools
    SyncExternalProjectWorker.stubs(:perform_async).raises(RedisClient::CannotConnectError)
    assert_raises(RedisClient::CannotConnectError) { DiscoverExternalRepositoriesWorker.new.perform }
    assert record.reload.discovered_at
    assert_equal 1, Project.count
    assert_equal 1, ExternalProjectSync.pending.count
    SyncExternalProjectWorker.unstub(:perform_async)
    discover
    assert_equal 1, SyncExternalProjectWorker.jobs.size
    assert_equal 1, Project.count
  end

  test "discovery queries use bounded IDs and omit full project metadata for existing matches" do
    Project.create!(url: "https://github.com/theislab/scanpy", science_score: 42, last_synced_at: 1.day.ago)
    import_biotools
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") { discover(1) }
    selection = queries.find { |sql| sql.include?('SELECT "external_software_records"."id"') }
    assert_match "LIMIT", selection
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "projects"') }
    assert_equal 2, reads.size
    reads.each do |sql|
      refute_includes sql, '"projects".*'
      refute_includes sql, '"projects"."repository"'
      assert_match /"projects"\."url" (IN|=)/, sql
    end
  end
end
