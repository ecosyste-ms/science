require "test_helper"
require "rake"
require_relative "../support/swmath_pipeline"

class ImportSwmathWorkerTest < ActiveSupport::TestCase
  include SwmathPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swmath:sweep")
    @project = Project.create!(url: "https://github.com/numpy/numpy", science_score: 42)
  end

  def invoke_task(name, **env)
    previous = env.to_h { |key, value| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "rake sweep saves bounded cursor pages and completes on the explicit terminal response" do
    swmath_page(after: "0", ids: %w[6293 6294], total: 3)
    swmath_page(after: "6294", ids: %w[14241])
    assert_equal 2, JSON.parse(invoke_task("swmath:sweep", LIMIT: 2))["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "swmath")
    ImportSwmathWorker.perform_one
    assert_equal "6294", import.reload.cursor
    assert_equal 2, import.items_processed
    assert_equal "6294", @project.external_software_records.sole.identifier
    assert_empty import.pending_records
    travel_to import.next_run_at + 1.second do
      ImportSwmathWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 3, import.items_processed
    assert_equal "14241", import.cursor
    assert_equal true, JSON.parse(invoke_task("swmath:status"))["complete"]
    assert_equal false, JSON.parse(invoke_task("swmath:resume"))["queued"]
    invoke_task("swmath:sweep", RESTART: true, LIMIT: 2)
    ImportSwmathWorker.perform_one
    swmath_page(after: "6294", ids: [], body: swmath_missing(code: 404), status: 404)
    travel_to import.reload.next_run_at + 1.second do
      ImportSwmathWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal "6294", import.cursor
    assert_equal 2, import.items_processed
  end

  test "saved pages survive interruption and do not overwrite a newer manual import" do
    swmath_page(after: "0", ids: %w[6293 6294])
    invoke_task("swmath:sweep", LIMIT: 2)
    SwmathImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportSwmathWorker.perform_one }
    SwmathImporter.any_instance.unstub(:sync_page)
    import = ExternalSoftwareImport.find_by!(source: "swmath")
    assert_equal 2, import.pending_records.size
    assert_nil import.cursor
    assert_equal 0, import.items_processed
    assert_nil import.lease_token
    travel 1.minute do
      @swmath["6294"]["name"] = "Updated NumPy"
      swmath_record("6294")
      sync_swmath(["6294"])
    end
    WebMock.reset!
    travel_to import.next_run_at + 1.second do
      invoke_task("swmath:resume")
      ImportSwmathWorker.perform_one
    end
    assert_equal 2, import.reload.items_processed
    assert_empty import.pending_records
    assert_equal "Updated NumPy", @project.external_software_records.sole.metadata["name"]
    assert_not_requested :any, /api.zbmath.org/
  end

  test "invalid unordered duplicate truncated and mismatched pages never advance progress" do
    invoke_task("swmath:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "swmath")
    bodies = [
      swmath_response([@swmath["6294"], @swmath["6293"]], last_id: 6293),
      swmath_response([@swmath["6294"], @swmath["6294"]], last_id: 6294),
      swmath_response([@swmath["6294"]], total: 2, last_id: 6294),
      swmath_response([@swmath["6293"], @swmath["6294"]], last_id: 825),
      swmath_response([@swmath["6294"].except("source_code")], last_id: 6294),
      swmath_response([], last_id: nil), { "result" => [], "status" => {} }
    ]
    bodies.each do |body|
      swmath_page(after: "0", ids: [], body: body)
      travel_to import.next_run_at + 1.second do
        ImportSwmathWorker.new.perform(import.id)
      end
      assert import.reload.last_error
      assert_nil import.cursor
      assert_nil import.completed_at
      assert_equal 0, import.items_processed
      assert_empty import.pending_records
      assert_empty ExternalSoftwareRecord.all
    end
  end

  test "terminal response must be explicit and cannot finish an empty initial import" do
    invoke_task("swmath:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "swmath")
    swmath_page(after: "0", ids: [], body: swmath_missing(code: 404), status: 404)
    ImportSwmathWorker.perform_one
    assert_nil import.reload.completed_at
    assert_match "Invalid", import.last_error
    import.update!(cursor: "6294", next_run_at: Time.current)
    swmath_page(after: "6294", ids: [], body: { result: nil, status: {} }, status: 404)
    ImportSwmathWorker.new.perform(import.id)
    assert_nil import.reload.completed_at
    assert_match "Invalid", import.last_error
    travel_to import.next_run_at + 1.second do
      swmath_page(after: "6294", ids: %w[6293 6294])
      ImportSwmathWorker.new.perform(import.id)
    end
    assert_match "cursor", import.reload.last_error
    assert_equal "6294", import.cursor
  end

  test "leases cooldown and scheduled recovery preserve progress without starting new sweeps" do
    assert_equal false, JSON.parse(invoke_task("swmath:resume"))["queued"]
    assert_raises(ArgumentError) { invoke_task("swmath:sweep", LIMIT: 51) }
    invoke_task("swmath:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "swmath")
    assert_raises(ArgumentError) { invoke_task("swmath:sweep", RESTART: true) }
    assert_raises(ArgumentError) { invoke_task("swmath:sweep", LIMIT: 3) }
    token = import.claim
    assert_nil import.claim
    assert_nil import.advance_catalogue("wrong-token")
    import.defer(token, Time.current, "retry")
    stub_request(:get, "#{SwmathClient::API_URL}/_all").with(query: { start_after: "0", results_per_request: 2 })
      .to_return(status: 503, headers: { "Retry-After" => "600" })
    travel_to import.next_run_at + 1.second do
      ImportSwmathWorker.new.perform(import.id)
      assert import.reload.next_run_at >= 9.minutes.from_now
    end
    assert_nil import.cursor
    assert_nil import.lease_token
    assert_match "rate limit", import.last_error
  end

  test "manual tasks deduplicate and refresh selects only bounded due swMATH records" do
    swmath_record("6294")
    assert_equal 1, JSON.parse(invoke_task("swmath:import", IDS: "6294,6294"))["queued"]
    SyncSwmathWorker.perform_one
    assert_equal 0, JSON.parse(invoke_task("swmath:refresh"))["queued"]
    expire_swmath
    ExternalSoftwareRecord.create!(source: "swmath", identifier: "825", next_refresh_at: 1.day.ago)
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "1010.083", next_refresh_at: 1.day.ago)
    assert_equal 1, JSON.parse(invoke_task("swmath:refresh", LIMIT: 1))["queued"]
    assert_equal [["825"]], SyncSwmathWorker.jobs.map { |job| job["args"].first }
    assert_raises(ArgumentError) { invoke_task("swmath:import", IDS: "0") }
    assert_raises(ArgumentError) { invoke_task("swmath:refresh", LIMIT: 1001) }
  end

  test "cached discovery creates one repository and citation count changes do not repeatedly sync zero-score projects" do
    @swmath["825"]["source_code"] = "https://sagemath.github.io/sage/docs/"
    swmath_record("825")
    invoke_task("swmath:import", IDS: "825")
    SyncSwmathWorker.perform_one
    assert_difference "Project.count", 1 do
      DiscoverExternalRepositoriesWorker.new.perform(1)
    end
    project = Project.find_by!(url: "https://github.com/sagemath/sage")
    assert_equal 0, project.science_score.to_f
    assert_equal "825", project.external_software_records.sole.identifier
    assert_equal "github_pages", project.project_external_software_records.sole.evidence.sole["url_transformation"]
    request = ExternalProjectSync.find_by!(project_id: project.id)
    request.update!(completed_at: request.requested_at)
    expire_swmath
    @swmath["825"]["articles_count"] = 999999
    swmath_record("825")
    sync_swmath(["825"])
    assert_no_difference "Project.count" do
      DiscoverExternalRepositoriesWorker.new.perform(1)
    end
    assert_empty ExternalProjectSync.pending
  ensure
    SyncExternalProjectWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncExternalProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end
end
