require "test_helper"
require "rake"
require_relative "../support/rrid_pipeline"

class ImportRridWorkerTest < ActiveSupport::TestCase
  include RridPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("rrid:sweep")
    @original_key = ENV["SCICRUNCH_API_KEY"]
    ENV["SCICRUNCH_API_KEY"] = "rrid-test-key"
    @project = Project.create!(url: "https://github.com/mikelove/deseq2", science_score: 42)
  end

  teardown { @original_key ? ENV["SCICRUNCH_API_KEY"] = @original_key : ENV.delete("SCICRUNCH_API_KEY") }

  def invoke_task(name, **env)
    previous = env.to_h { |key, value| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "rake sweep saves bounded identifier pages and reuses known RRIDs without changing scores" do
    rrid_record("SCR_015687")
    sync_rrid(["SCR_015687"])
    before = @project.attributes
    rrid_page(ids: ["SCR_015687"], limit: 1, total: 2)
    rrid_page(after: "SCR_015687", ids: ["SCR_026162"], limit: 1)
    assert_equal 1, JSON.parse(invoke_task("rrid:sweep", LIMIT: 1))["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "rrid")
    ImportRridWorker.perform_one
    assert_equal "SCR_015687", import.reload.cursor
    assert_equal 1, import.items_processed
    record = @project.external_software_records.sole
    assert_equal RridCatalogueClient::API_URL, record.collection_url
    assert_equal RridCatalogueClient::API_URL, @project.project_external_software_records.sole.evidence.sole["collection_url"]
    assert_equal before, @project.reload.attributes
    travel_to import.next_run_at + 1.second do
      ImportRridWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal "SCR_026162", import.cursor
    assert_equal 2, import.items_processed
    assert_equal 2, ExternalSoftwareRecord.count
    assert_equal true, JSON.parse(invoke_task("rrid:sweep_status"))["complete"]
    invoke_task("rrid:sweep", RESTART: true, LIMIT: 1)
    ImportRridWorker.perform_one
    assert_equal 2, ExternalSoftwareRecord.count
  end

  test "saved pages survive interruption without fetching again or replacing newer resolver metadata" do
    request = rrid_page(ids: %w[SCR_015687 SCR_026162])
    invoke_task("rrid:sweep", LIMIT: 2)
    RridImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportRridWorker.perform_one }
    RridImporter.any_instance.unstub(:sync_page)
    import = ExternalSoftwareImport.find_by!(source: "rrid")
    assert_equal 2, import.pending_records.size
    assert_equal 0, import.items_processed
    assert_nil import.cursor
    assert_nil import.lease_token
    travel 1.minute do
      @rrid["SCR_015687"]["item"]["name"] = "Updated DESeq2"
      rrid_record("SCR_015687")
      sync_rrid(["SCR_015687"])
    end
    travel_to import.next_run_at + 1.second do
      invoke_task("rrid:resume")
      ImportRridWorker.perform_one
    end
    assert import.reload.completed_at
    record = @project.external_software_records.sole
    assert_equal "Updated DESeq2", record.metadata.dig("item", "name")
    assert_equal "https://scicrunch.org/resolver/SCR_015687.json", record.collection_url
    assert_requested request, times: 1
  end

  test "retry after a lost response resumes from the saved ID without an upstream session" do
    rrid_page(ids: ["SCR_015687"], limit: 1, total: 2)
    invoke_task("rrid:sweep", LIMIT: 1)
    ImportRridWorker.perform_one
    import = ExternalSoftwareImport.find_by!(source: "rrid")
    request = stub_request(:post, RridCatalogueClient::API_URL)
      .with { |request| JSON.parse(request.body).dig("query", "bool", "filter").last == { "range" => { "item.identifier.aggregate" => { "gt" => "scr_015687" } } } }
      .to_timeout.then.to_return(status: 200, body: rrid_catalogue_response([@rrid["SCR_026162"]]).to_json)
    travel_to import.next_run_at + 1.second do
      ImportRridWorker.perform_one
    end
    assert_equal "SCR_015687", import.reload.cursor
    assert_nil import.completed_at
    assert_match "request failed", import.last_error
    travel_to import.next_run_at + 2.days do
      invoke_task("rrid:resume")
      ImportRridWorker.new.perform(import.id)
    end
    assert import.reload.completed_at
    assert_equal 2, import.items_processed
    assert_requested request, times: 2
  end

  test "partial unordered duplicate mismatched and nonsoftware pages cannot advance the cursor" do
    invoke_task("rrid:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "rrid")
    valid = rrid_catalogue_response([@rrid["SCR_015687"], @rrid["SCR_026162"]])
    wrong_sort = valid.deep_dup
    wrong_sort["hits"]["hits"][0]["sort"] = ["scr_000001"]
    bodies = [{}, valid.merge("timed_out" => true),
      valid.merge("_shards" => { "total" => 2, "successful" => 1, "failed" => 1 }),
      rrid_catalogue_response([@rrid["SCR_026162"], @rrid["SCR_015687"]]),
      rrid_catalogue_response([@rrid["SCR_015687"], @rrid["SCR_015687"]]),
      rrid_catalogue_response([@rrid["SCR_015687"]], total: 3),
      rrid_catalogue_response([@rrid["SCR_005400"]]),
      rrid_catalogue_response([@rrid["SCR_015687"].except("distributions")]), wrong_sort,
      valid.merge("hits" => { "total" => 1, "hits" => ["malformed"] })]
    bodies.each do |body|
      rrid_page(body: body)
      travel_to import.next_run_at + 1.second do
        ImportRridWorker.new.perform(import.id)
      end
      assert import.reload.last_error
      assert_nil import.cursor
      assert_nil import.completed_at
      assert_equal 0, import.items_processed
      assert_empty import.pending_records
      assert_empty ExternalSoftwareRecord.all
    end
    import.update!(cursor: "SCR_026162", next_run_at: Time.current)
    rrid_page(after: "SCR_026162", ids: ["SCR_015687"])
    ImportRridWorker.new.perform(import.id)
    assert_match "cursor", import.reload.last_error
    assert_equal "SCR_026162", import.cursor
  end

  test "empty filtered response completes while missing keys HTTP errors and cooldowns retain progress" do
    assert_equal false, JSON.parse(invoke_task("rrid:resume"))["queued"]
    assert_raises(ArgumentError) { invoke_task("rrid:sweep", LIMIT: 51) }
    invoke_task("rrid:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "rrid")
    assert_raises(ArgumentError) { invoke_task("rrid:sweep", RESTART: true) }
    ENV.delete("SCICRUNCH_API_KEY")
    ImportRridWorker.perform_one
    assert_match "SCICRUNCH_API_KEY", import.reload.last_error
    assert_not_requested :post, RridCatalogueClient::API_URL
    ENV["SCICRUNCH_API_KEY"] = "rrid-test-key"
    [401, 403, 500].each do |status|
      rrid_page(status: status)
      travel_to import.next_run_at + 1.second do
        ImportRridWorker.new.perform(import.id)
      end
      assert_match "HTTP #{status}", import.reload.last_error
      refute_includes import.last_error, "rrid-test-key"
    end
    WebMock.reset!
    request = rrid_page(status: 429, headers: { "Retry-After" => "600" })
    travel_to import.next_run_at + 1.second do
      ImportRridWorker.new.perform(import.id)
      assert import.reload.next_run_at >= 9.minutes.from_now
      assert_raises(RridClient::RateLimited) { RridClient.new.record("SCR_015687") }
    end
    assert_requested request, times: 1
    rrid_page(ids: [])
    travel_to import.next_run_at + 1.second do
      ImportRridWorker.new.perform(import.id)
    end
    assert import.reload.completed_at
    assert_equal 0, import.items_processed
  end

  test "cached discovery reuses collection provenance and ignores changing mention counts" do
    rrid_page(ids: %w[SCR_015687 SCR_026162])
    invoke_task("rrid:sweep", LIMIT: 2)
    ImportRridWorker.perform_one
    assert_difference "Project.count", 1 do
      DiscoverExternalRepositoriesWorker.new.perform(2)
    end
    trust = Project.find_by!(url: "https://github.com/liulab-dfci/trust4")
    assert_equal RridCatalogueClient::API_URL, trust.project_external_software_records.sole.evidence.sole["collection_url"]
    assert_equal RridCatalogueClient::API_URL, trust.external_software_records.sole.collection_url
    request = ExternalProjectSync.find_by!(project_id: trust.id)
    request.update!(completed_at: request.requested_at)
    @rrid["SCR_026162"]["mentions"] = { "count" => 999999 }
    rrid_page(ids: %w[SCR_015687 SCR_026162])
    invoke_task("rrid:sweep", RESTART: true, LIMIT: 2)
    ImportRridWorker.perform_one
    assert_no_difference "Project.count" do
      DiscoverExternalRepositoriesWorker.new.perform(2)
    end
    assert_not ExternalProjectSync.pending.where(project_id: trust.id).exists?
    assert_equal 0, trust.reload.science_score.to_f
  ensure
    SyncExternalProjectWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncExternalProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end
end
