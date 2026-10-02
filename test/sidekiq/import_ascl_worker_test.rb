require "test_helper"
require "rake"
require_relative "../support/ascl_pipeline"

class ImportAsclWorkerTest < ActiveSupport::TestCase
  include AsclPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ascl:sweep")
    @project = Project.create!(url: "https://github.com/mesahub/mesa", science_score: 42)
  end

  def invoke_task(name, **env)
    previous = env.to_h { |key, value| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "rake sweep persists bounded pages from one cached catalogue and resumes to completion" do
    request = ascl_catalogue
    output = JSON.parse(invoke_task("ascl:sweep", LIMIT: 2))
    assert_equal 2, output["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "ascl")
    ImportAsclWorker.perform_one
    assert_equal 2, import.reload.items_processed
    assert_equal "1110.016", import.cursor
    assert_equal 2, ExternalSoftwareRecord.count
    assert_empty import.pending_records
    assert_nil import.completed_at
    assert_equal "1010.083", @project.external_software_records.sole.identifier
    2.times do
      travel_to import.next_run_at + 1.second do
        ImportAsclWorker.perform_one
      end
      import.reload
    end
    assert import.completed_at
    assert_equal 6, import.items_processed
    assert_equal 3, import.pages_processed
    assert_equal "2204.014", import.cursor
    assert_equal 6, ExternalSoftwareRecord.count
    assert_requested request, times: 1
    assert_equal true, JSON.parse(invoke_task("ascl:status"))["complete"]
    assert_equal false, JSON.parse(invoke_task("ascl:resume"))["queued"]
  end

  test "interrupted saved page resumes without fetching upstream or advancing early" do
    ascl_catalogue
    invoke_task("ascl:sweep", LIMIT: 2)
    AsclImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportAsclWorker.perform_one }
    import = ExternalSoftwareImport.find_by!(source: "ascl")
    assert_equal 2, import.pending_records.size
    assert_nil import.cursor
    assert_equal 0, import.items_processed
    assert_nil import.lease_token
    AsclImporter.any_instance.unstub(:sync_page)
    Rails.cache.delete(AsclClient::CACHE_KEY)
    WebMock.reset!
    travel_to import.next_run_at + 1.second do
      invoke_task("ascl:resume")
      ImportAsclWorker.perform_one
    end
    assert_equal 2, import.reload.items_processed
    assert_empty import.pending_records
    assert_equal 2, ExternalSoftwareRecord.count
    assert_not_requested :any, /ascl.net/
  end

  test "stale saved pages cannot overwrite later source observations" do
    ascl_catalogue
    invoke_task("ascl:sweep", LIMIT: 2)
    AsclImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportAsclWorker.perform_one }
    AsclImporter.any_instance.unstub(:sync_page)
    import = ExternalSoftwareImport.find_by!(source: "ascl")
    travel 1.minute do
      @ascl["1010.083"]["title"] = "MESA updated"
      expire_ascl
      ascl_catalogue
      sync_ascl(["1010.083"])
    end
    travel_to import.next_run_at + 1.second do
      ImportAsclWorker.new.perform(import.id)
    end
    assert_equal "MESA updated", ExternalSoftwareRecord.find_by!(identifier: "1010.083").metadata["title"]
    assert_equal 2, import.reload.items_processed
  end

  test "leases and retries retain progress through malformed catalogues and rate limits" do
    ascl_catalogue(status: 503, headers: { "Retry-After" => "600" })
    invoke_task("ascl:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "ascl")
    token = import.claim
    assert_nil import.claim
    assert_nil import.advance_catalogue("wrong-token")
    import.defer(token, Time.current, "retry")
    travel_to import.next_run_at + 1.second do
      ImportAsclWorker.new.perform(import.id)
    end
    assert_match "rate limit", import.reload.last_error
    assert_nil import.cursor
    assert_nil import.lease_token
    assert_equal 0, import.items_processed
    travel_to import.next_run_at + 1.second do
      stub_request(:get, AsclClient::CATALOGUE_URL).to_return(body: "<html>Unavailable</html>")
      ImportAsclWorker.new.perform(import.id)
    end
    assert_match "JSON", import.reload.last_error
    assert_empty import.pending_records
  end

  test "scheduled recovery never starts or restarts a sweep but explicit restart does" do
    assert_equal false, JSON.parse(invoke_task("ascl:resume"))["queued"]
    ascl_catalogue(@ascl.values.first(1))
    invoke_task("ascl:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "ascl")
    assert_raises(ArgumentError) { invoke_task("ascl:sweep", RESTART: true) }
    assert_raises(ArgumentError) { invoke_task("ascl:sweep", LIMIT: 3) }
    ImportAsclWorker.perform_one
    assert import.reload.completed_at
    assert_equal false, JSON.parse(invoke_task("ascl:resume"))["queued"]
    invoke_task("ascl:sweep", RESTART: true)
    assert_nil import.reload.completed_at
    assert_nil import.cursor
    assert_equal 0, import.items_processed
  end

  test "manual imports validate IDs and refresh selects a bounded set of due records" do
    ascl_catalogue
    assert_equal 1, JSON.parse(invoke_task("ascl:import", IDS: "1010.083,1010.083"))["queued"]
    SyncAsclWorker.perform_one
    assert_equal 0, JSON.parse(invoke_task("ascl:refresh"))["queued"]
    expire_ascl
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "2501.001", next_refresh_at: 1.day.ago)
    ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q1", next_refresh_at: 1.day.ago)
    assert_equal 1, JSON.parse(invoke_task("ascl:refresh", LIMIT: 1))["queued"]
    assert_equal [["2501.001"]], SyncAsclWorker.jobs.map { |job| job["args"].first }
    assert_raises(ArgumentError) { invoke_task("ascl:import", IDS: "0000.000") }
    assert_raises(ArgumentError) { invoke_task("ascl:refresh", LIMIT: 1001) }
  end

  test "cached source records feed discovery and view counts do not cause repeated zero-score syncs" do
    @ascl["1110.016"]["site_list"] = ["https://HannoRein.github.io/rebound/docs/"]
    ascl_catalogue
    invoke_task("ascl:import", IDS: "1110.016")
    SyncAsclWorker.perform_one
    assert_difference "Project.count", 1 do
      DiscoverExternalRepositoriesWorker.new.perform(1)
    end
    project = Project.find_by!(url: "https://github.com/hannorein/rebound")
    assert_equal 0, project.science_score.to_f
    assert_equal "1110.016", project.external_software_records.sole.identifier
    assert_equal "github_pages", project.project_external_software_records.sole.evidence.sole["url_transformation"]
    request = ExternalProjectSync.find_by!(project_id: project.id)
    request.update!(completed_at: request.requested_at)
    expire_ascl
    @ascl["1110.016"]["views"] = "999999"
    ascl_catalogue
    sync_ascl(["1110.016"])
    DiscoverExternalRepositoriesWorker.new.perform(1)
    assert_empty ExternalProjectSync.pending
  ensure
    SyncExternalProjectWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncExternalProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end
end
