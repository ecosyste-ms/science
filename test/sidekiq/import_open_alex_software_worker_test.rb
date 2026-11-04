require "test_helper"
require "rake"
require_relative "../support/software_doi_pipeline"

class ImportOpenAlexSoftwareWorkerTest < ActiveSupport::TestCase
  include SoftwareDoiPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("open_alex:software:sweep")
    @previous_env = %w[OPENALEX_API_KEY LIMIT FROM UNTIL RESTART].index_with { |key| ENV[key] }
    ENV["OPENALEX_API_KEY"] = "test-key"
    %w[LIMIT FROM UNTIL RESTART].each { |key| ENV.delete(key) }
    clear_openalex_jobs
  end

  teardown do
    @previous_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    clear_openalex_jobs
  end

  def clear_openalex_jobs
    [ImportOpenAlexSoftwareWorker, SyncOpenAlexSoftwareWorker, DiscoverExternalRepositoriesWorker].each(&:clear)
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncOpenAlexSoftwareWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def task(name, **env)
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    JSON.parse(capture_io { Rake::Task[name].invoke }.first)
  end

  def work(id, doi: nil, url: nil)
    { "id" => "https://openalex.org/#{id}", "type" => "software", "doi" => doi && "https://doi.org/#{doi}",
      "display_name" => "Research software #{id}", "created_date" => "2020-01-01", "updated_date" => "2026-11-01T00:00:00Z",
      "primary_location" => { "landing_page_url" => url }, "locations" => [{ "landing_page_url" => url }] }
  end

  def page(rows, cursor: "*", next_cursor: nil, status: 200, headers: {})
    stub_request(:get, "https://api.openalex.org/works").with(query: hash_including(
      "api_key" => "test-key", "sort" => "ids.openalex:asc", "cursor" => cursor, "per_page" => "2"))
      .to_return(status: status, headers: headers,
        body: { meta: { count: 3, next_cursor: next_cursor }, results: rows }.to_json)
  end

  def start
    task("open_alex:software:sweep", LIMIT: 2, UNTIL: "2026-11-03")
    ExternalSoftwareImport.find_by!(source: "openalex")
  end

  test "rake enumeration saves works and resumes a nonempty final page independently of hydration" do
    first = page([work("W100"), work("W101")], next_cursor: "opaque/+==")
    second = page([work("W102")], cursor: "opaque/+==")
    import = start
    ImportOpenAlexSoftwareWorker.perform_one
    assert_equal 2, import.reload.items_processed
    assert_equal "opaque/+==", JSON.parse(import.cursor)["token"]
    assert_equal ["pending"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_not_requested :any, /datacite.org|zenodo.org/
    assert_empty Project.all
    travel_to import.next_run_at + 1.second do
      ImportOpenAlexSoftwareWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 3, import.items_processed
    assert_equal 2, import.pages_processed
    assert_equal 3, ExternalSoftwareRecord.count
    assert_equal false, task("open_alex:software:resume")["queued"]
    assert_requested first, times: 1
    assert_requested second, times: 1
  end

  test "saved page survives a database failure and replays without another API request" do
    request = page([work("W100"), work("W101")])
    import = start
    OpenAlexSoftwareImporter.any_instance.stubs(:sync_page).raises(ActiveRecord::Deadlocked)
    assert_raises(ActiveRecord::Deadlocked) { ImportOpenAlexSoftwareWorker.perform_one }
    assert_equal 2, import.reload.pending_records.size
    assert_equal "*", JSON.parse(import.cursor)["token"]
    assert_equal 0, ExternalSoftwareRecord.count
    OpenAlexSoftwareImporter.any_instance.unstub(:sync_page)
    travel_to import.next_run_at + 1.second do
      task("open_alex:software:resume")
      ImportOpenAlexSoftwareWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 2, ExternalSoftwareRecord.count
    assert_requested request, times: 1
  end

  test "malformed ordering and repeated tokens leave the checkpoint unchanged" do
    import = start
    page([work("W101"), work("W100")])
    ImportOpenAlexSoftwareWorker.perform_one
    assert_match "ID order", import.reload.last_error
    assert_equal 0, import.items_processed
    assert_empty import.pending_records
    travel_to import.next_run_at + 1.second do
      page([work("W100")], next_cursor: "*")
      ImportOpenAlexSoftwareWorker.new.perform(import.id)
    end
    assert_match "ID order", import.reload.last_error
    assert_empty ExternalSoftwareRecord.all
  end

  test "date bounds and page size cannot change on resume" do
    import = start
    assert_raises(ArgumentError) { task("open_alex:software:sweep", UNTIL: "2026-11-02") }
    ENV.delete("UNTIL")
    assert_raises(ArgumentError) { task("open_alex:software:sweep", LIMIT: 3) }
    assert_raises(ArgumentError) { ExternalSoftwareImport.start_open_alex(restart: true) }
    assert_equal "2026-11-03", JSON.parse(import.reload.cursor)["until"]
  end

  test "rate limits preserve the page and retry time without sleeping" do
    page([], status: 429, headers: { "Retry-After" => "3600" })
    import = start
    Faraday::Retry::Middleware.any_instance.expects(:sleep).never
    ImportOpenAlexSoftwareWorker.perform_one
    assert_equal 0, import.reload.items_processed
    assert_in_delta 1.hour.from_now.to_f, import.next_run_at.to_f, 2
    assert_nil import.lease_token
  end

  test "hydration and existing discovery match aliases and collapse works onto one new repository" do
    id = "10.5281/zenodo.15878535"
    doi_record(id)
    page([work("W100", doi: id), work("W101", doi: id)])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    assert_equal 2, task("open_alex:software:refresh")["queued"]
    SyncOpenAlexSoftwareWorker.perform_one
    assert_equal ["ok"], ExternalSoftwareRecord.distinct.pluck(:status)
    assert_difference "Project.count", 1 do
      DiscoverExternalRepositoriesWorker.new.perform(2)
    end
    project = Project.sole
    assert_equal 2, project.external_software_records.count
    assert_equal ["repository_candidate"], project.project_external_software_records.distinct.pluck(:relationship)
    assert_equal 0, project.science_score.to_f
    refute project.confirmed_external_identifier?
    assert_equal 1, ExternalProjectSync.pending.count
    assert project.project_external_software_records.all? { |link| link.evidence.all? { |item| item["openalex_work_id"].present? } }
    assert_equal ["OpenAlex"], project.project_external_software_records.registry_references.pluck(:source).uniq
  end

  test "direct repository URLs resolve existing aliases without creating duplicates or guessing names" do
    project = Project.create!(url: "https://github.com/scverse/scanpy", science_score: 42, last_synced_at: Time.current)
    project.repository_aliases.create!(url: "https://github.com/theislab/scanpy")
    page([work("W100", url: "https://github.com/TheisLab/Scanpy/tree/main"), work("W101", url: "https://example.org/software")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    assert_no_difference "Project.count" do
      DiscoverExternalRepositoriesWorker.new.perform(2)
    end
    assert_equal ["W100"], project.external_software_records.pluck(:identifier)
    assert_equal 42, project.reload.science_score
    assert_empty ExternalProjectSync.all
  end

  test "dataset metadata suppresses repository candidates and successful reclassification removes old links" do
    id = "10.5281/zenodo.15878535"
    dataset = @datacite.fetch(id).deep_dup
    dataset["attributes"]["types"]["resourceTypeGeneral"] = "Dataset"
    datacite_record(id, body: { data: dataset })
    page([work("W100", doi: id, url: "https://github.com/example/data")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform
    assert_empty Project.all
    assert_not_requested :any, /zenodo.org/
    record = ExternalSoftwareRecord.sole
    record.update!(next_refresh_at: 1.second.ago)
    stub_request(:get, "https://api.openalex.org/works/W100").with(query: hash_including("api_key" => "test-key"))
      .to_return(body: work("W100").merge("type" => "dataset").to_json)
    SyncOpenAlexSoftwareWorker.new.perform(["W100"])
    assert_equal "dataset", record.reload.metadata.dig("openalex", "type")
    assert_empty record.project_external_software_records
  end

  test "hydration failures retain the other saved works for a bounded retry" do
    id = "10.5281/zenodo.15878535"
    datacite_record(id, status: 503, headers: { "Retry-After" => "600" })
    page([work("W100", doi: id), work("W101")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: "W100").status
    assert_equal "pending", ExternalSoftwareRecord.find_by!(identifier: "W101").status
    assert_equal 1, SyncOpenAlexSoftwareWorker.jobs.size
    assert ExternalSoftwareImport.sole.completed_at
  end

  test "a refreshed work reclassified away from software withdraws repository links" do
    page([work("W100", url: "https://github.com/research/tool")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform
    record = ExternalSoftwareRecord.sole
    assert_equal 1, record.project_external_software_records.count
    record.update!(next_refresh_at: 1.second.ago)
    stub_request(:get, "https://api.openalex.org/works/W100").with(query: hash_including("api_key" => "test-key"))
      .to_return(body: work("W100").merge("type" => "dataset").to_json)
    SyncOpenAlexSoftwareWorker.new.perform(["W100"])
    assert_empty record.project_external_software_records.reload
    assert_equal 1, Project.count
  end

  test "hidden repository owners remain excluded for OpenAlex candidates" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "github")
    host.owners.create!(login: "hidden-lab", hidden: true)
    page([work("W100", url: "https://github.com/hidden-lab/tool")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform
    assert_empty Project.all
    assert_equal "hidden", ExternalSoftwareRecord.sole.discovery_result["repositories"].sole["status"]
  end

  test "an older catalogue page cannot overwrite newer hydrated evidence" do
    page([work("W100", url: "https://github.com/research/tool")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    record = ExternalSoftwareRecord.sole
    original = record.metadata.deep_dup
    OpenAlexSoftwareImporter.new.sync_page([work("W100", url: "https://github.com/research/old")], started_at: 1.hour.ago)
    assert_equal original, record.reload.metadata
    assert_equal "ok", record.status
  end

  test "a DOI absent from DataCite does not invalidate an explicit OpenAlex repository location" do
    id = "10.1234/research"
    datacite_record(id, status: 404, body: { errors: [{ status: "404" }] })
    page([work("W100", doi: id, url: "https://github.com/research/tool")])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform
    assert_equal "https://github.com/research/tool", Project.sole.url
    assert_equal true, ExternalSoftwareRecord.sole.metadata.dig("software_doi", "missing")
  end

  test "primary locations retain their own provenance through repository discovery" do
    payload = work("W100", url: "https://github.com/research/primary")
    payload["locations"] = []
    page([payload])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform

    evidence = Project.sole.project_external_software_records.sole.evidence.sole
    assert_equal "openalex.primary_location.landing_page_url", evidence["source_field"]
  end

  test "deduplicating locations preserves their original array positions" do
    payload = work("W100", url: "https://github.com/research/first")
    payload["locations"] = [payload["primary_location"], payload["primary_location"],
      { "landing_page_url" => "https://github.com/research/last" }]
    page([payload])
    start
    ImportOpenAlexSoftwareWorker.perform_one
    task("open_alex:software:refresh")
    SyncOpenAlexSoftwareWorker.perform_one
    DiscoverExternalRepositoriesWorker.new.perform

    first = Project.find_by!(url: "https://github.com/research/first")
    last = Project.find_by!(url: "https://github.com/research/last")
    assert_equal "openalex.locations[0].landing_page_url", first.project_external_software_records.sole.evidence.sole["source_field"]
    assert_equal "openalex.locations[2].landing_page_url", last.project_external_software_records.sole.evidence.sole["source_field"]
  end

  test "sweep retry decisions use the exact reason instead of diagnostic text" do
    import = start
    ["Plan upgrade required", "Temporary error mentioning Plan upgrade required"].each do |reason|
      stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("api_key" => "test-key"))
        .to_return(status: 429, headers: { "Retry-After" => "3600" }, body: { error: reason }.to_json)
      ImportOpenAlexSoftwareWorker.clear
      Faraday::Retry::Middleware.any_instance.expects(:sleep).never
      ImportOpenAlexSoftwareWorker.new.perform(import.id)

      assert_equal(reason == "Plan upgrade required" ? 0 : 1, ImportOpenAlexSoftwareWorker.jobs.size)
      assert_includes import.reload.last_error, reason
      assert_equal "*", JSON.parse(import.cursor)["token"]
      travel_to import.next_run_at + 1.second
    end
  ensure
    travel_back
  end
end
