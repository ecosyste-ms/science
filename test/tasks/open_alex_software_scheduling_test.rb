require "test_helper"
require "rake"
require_relative "../support/journal_schedule"

class OpenAlexSoftwareSchedulingTest < ActiveSupport::TestCase
  include JournalSchedule

  setup do
    Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
    Rails.application.load_tasks unless Rake::Task.task_defined?("open_alex:software:harvest")
    @previous_env = %w[LIMIT FROM UNTIL RESTART OPENALEX_API_KEY].index_with { |key| ENV[key] }
    %w[LIMIT FROM UNTIL RESTART].each { |key| ENV.delete(key) }
    ENV["OPENALEX_API_KEY"] = "test-key"
    ImportOpenAlexSoftwareWorker.clear
    clear_hydration
  end

  teardown do
    @previous_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    ImportOpenAlexSoftwareWorker.clear
    clear_hydration
  end

  def clear_hydration
    SyncOpenAlexSoftwareWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncOpenAlexSoftwareWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def invoke_task(name)
    Rake::Task[name].reenable
    JSON.parse(capture_io { Rake::Task[name].invoke }.first)
  end

  [[400, "Invalid query"], [401, "Invalid API key"], [403, "Forbidden"],
    [429, "Plan upgrade required"]].each do |status, reason|
    test "HTTP #{status} #{reason} blocks recovery until explicitly retried" do
      scheduled_journal_tasks("open_alex:software", "harvest")
      first = stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("cursor" => "*"))
        .to_return(body: { results: [{ id: "https://openalex.org/W100", type: "software" }],
          meta: { next_cursor: "saved/+==" } }.to_json)
      ImportOpenAlexSoftwareWorker.perform_one
      import = ExternalSoftwareImport.find_by!(source: "openalex")
      checkpoint = import.cursor
      failed = stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("cursor" => "saved/+=="))
        .to_return(status: status, headers: { "Retry-After" => "3600" }, body: { error: reason }.to_json)
      travel_to import.next_run_at + 1.second do
        ImportOpenAlexSoftwareWorker.perform_one
      end
      assert import.reload.open_alex_blocked?
      assert_nil import.lease_token
      assert_includes import.last_error, reason
      assert_nil import.completed_at
      assert_equal JSON.parse(checkpoint), JSON.parse(import.cursor).except("blocked")

      travel 8.days do
        assert_equal false, scheduled_journal_tasks("open_alex:software", "resume").first["queued"]
        assert_equal [{ "queued" => false }], scheduled_journal_tasks("open_alex:software", "harvest")
        invoke_task("open_alex:software:sweep")
        ImportOpenAlexSoftwareWorker.new.perform(import.id)
        assert_empty ImportOpenAlexSoftwareWorker.jobs
        assert_equal true, invoke_task("open_alex:software:status").dig("import", "blocked")
        assert_requested failed, times: 1

        recovered = stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("cursor" => "saved/+=="))
          .to_return(body: { results: [{ id: "https://openalex.org/W101", type: "software" }],
            meta: { next_cursor: nil } }.to_json)
        assert_equal({ "import_queued" => true, "records_unblocked" => 0 }, invoke_task("open_alex:software:retry"))
        assert_equal checkpoint, import.reload.cursor
        ImportOpenAlexSoftwareWorker.perform_one
        assert import.reload.completed_at
        assert_equal 2, import.items_processed
        refute import.open_alex_blocked?
        assert_requested recovered, times: 2
        assert_requested first, times: 1
      end
    end
  end

  [true, false].each do |retry_header|
    test "hydration plan restriction with retry header #{retry_header} stays blocked until explicitly retried" do
      scheduled_journal_tasks("open_alex:software", "harvest")
      works = [{ id: "https://openalex.org/W100", type: "software", display_name: "Original tool" },
        { id: "https://openalex.org/W101", type: "software" }]
      stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("cursor" => "*"))
        .to_return(body: { results: works, meta: { next_cursor: nil } }.to_json)
      ImportOpenAlexSoftwareWorker.perform_one
      scheduled_journal_tasks("open_alex:software", "resume")
      SyncOpenAlexSoftwareWorker.perform_one
      record = ExternalSoftwareRecord.find_by!(identifier: "W100")
      original = record.metadata

      failed = stub_request(:get, "https://api.openalex.org/works/W100")
        .with(query: hash_including("api_key" => "test-key"))
        .to_return(status: 429, headers: retry_header ? { "Retry-After" => "3600" } : {},
          body: { error: "Plan upgrade required" }.to_json)
      stub_request(:get, "https://api.openalex.org/works/W101")
        .with(query: hash_including("api_key" => "test-key"))
        .to_return(body: works.last.to_json)
      Faraday::Retry::Middleware.any_instance.stubs(:sleep)
      travel 31.days do
        scheduled_journal_tasks("open_alex:software", "resume")
        SyncOpenAlexSoftwareWorker.perform_one
        assert_equal "blocked", record.reload.status
        assert_equal original, record.metadata
        assert_includes record.last_error, "Plan upgrade required"
        assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "W101").status
        assert_empty SyncOpenAlexSoftwareWorker.jobs
      end

      travel 40.days do
        clear_hydration
        assert_equal 0, scheduled_journal_tasks("open_alex:software", "resume").last["queued"]
        SyncOpenAlexSoftwareWorker.new.perform(["W100"])
        assert_empty SyncOpenAlexSoftwareWorker.jobs
        scheduled_journal_tasks("open_alex:software", "harvest")
        ImportOpenAlexSoftwareWorker.perform_one
        assert_equal "blocked", record.reload.status
        assert_requested failed, times: retry_header ? 1 : 3

        recovered = stub_request(:get, "https://api.openalex.org/works/W100")
          .with(query: hash_including("api_key" => "test-key"))
          .to_return(body: works.first.merge(display_name: "Recovered tool").to_json)
        assert_equal({ "import_queued" => false, "records_unblocked" => 1 }, invoke_task("open_alex:software:retry"))
        assert_equal 1, scheduled_journal_tasks("open_alex:software", "resume").last["queued"]
        SyncOpenAlexSoftwareWorker.perform_one
        assert_equal "ok", record.reload.status
        assert_equal "Recovered tool", record.metadata.dig("openalex", "display_name")
        assert_nil record.last_error
        assert_requested recovered, times: retry_header ? 2 : 4
      end
    end
  end

  test "explicit retry only unblocks the bounded OpenAlex population" do
    3.times do |index|
      ExternalSoftwareRecord.create!(source: "openalex", identifier: "W#{100 + index}",
        status: "blocked", next_refresh_at: 1.day.from_now, last_error: "Plan upgrade required")
    end
    other = ExternalSoftwareRecord.create!(source: "ascl", identifier: "1010.083", status: "blocked", next_refresh_at: Time.current)
    ENV["LIMIT"] = "2"
    assert_equal({ "import_queued" => false, "records_unblocked" => 2 }, invoke_task("open_alex:software:retry"))
    assert_equal 1, ExternalSoftwareRecord.where(source: "openalex", status: "blocked").count
    assert_equal "blocked", other.reload.status
    assert_empty ImportOpenAlexSoftwareWorker.jobs
    ENV["LIMIT"] = "1001"
    assert_raises(ArgumentError) { invoke_task("open_alex:software:retry") }
    assert_equal 1, ExternalSoftwareRecord.where(source: "openalex", status: "blocked").count
  end

  test "ordinary hydration rate limits keep their retry time and recover automatically" do
    work = { id: "https://openalex.org/W100", type: "software", display_name: "Research tool" }
    record = ExternalSoftwareRecord.create!(source: "openalex", identifier: "W100", status: "ok",
      metadata: { openalex: work }, next_refresh_at: 1.day.ago)
    request = stub_request(:get, "https://api.openalex.org/works/W100")
      .with(query: hash_including("api_key" => "test-key"))
      .to_return(status: 429, headers: { "Retry-After" => "7200" },
        body: { error: "Temporary error mentioning Plan upgrade required" }.to_json)
    Faraday::Retry::Middleware.any_instance.expects(:sleep).never
    assert_equal 1, scheduled_journal_tasks("open_alex:software", "resume").last["queued"]
    SyncOpenAlexSoftwareWorker.perform_one
    assert_equal "error", record.reload.status
    assert_in_delta 2.hours.from_now.to_f, record.next_refresh_at.to_f, 2
    assert_equal 1, SyncOpenAlexSoftwareWorker.jobs.size
    assert_operator SyncOpenAlexSoftwareWorker.jobs.sole.fetch("at"), :>=, record.next_refresh_at.to_f
    travel 10.minutes do
      assert_equal 0, scheduled_journal_tasks("open_alex:software", "resume").last["queued"]
    end
    assert_requested request, times: 1
    stub_request(:get, "https://api.openalex.org/works/W100")
      .with(query: hash_including("api_key" => "test-key"))
      .to_return(body: work.to_json)
    travel_to Time.at(SyncOpenAlexSoftwareWorker.jobs.sole.fetch("at")) + 1.second do
      SyncOpenAlexSoftwareWorker.perform_one
    end
    assert_equal "ok", record.reload.status
    assert_nil record.last_error
    assert_empty SyncOpenAlexSoftwareWorker.jobs
  end

  test "weekly schedule starts the first sweep and its worker stores the returned page" do
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .find { |entry| entry["command"] == "bundle exec rake open_alex:software:harvest" }
    assert_equal "35 4 * * 0", cron.fetch("schedule")
    assert_equal [{ "queued" => true }], scheduled_journal_tasks("open_alex:software", "harvest")
    import = ExternalSoftwareImport.find_by!(source: "openalex")
    assert_equal 100, import.page_size
    assert_equal Date.yesterday.iso8601, JSON.parse(import.cursor)["until"]
    request = stub_request(:get, "https://api.openalex.org/works").with(query: hash_including(
      "api_key" => "test-key", "cursor" => "*", "per_page" => "100", "sort" => "ids.openalex:asc"))
      .to_return(body: { results: [{ id: "https://openalex.org/W100", type: "software", doi: nil }],
        meta: { next_cursor: nil } }.to_json)
    ImportOpenAlexSoftwareWorker.perform_one
    assert import.reload.completed_at
    assert_equal 1, import.items_processed
    assert_equal "W100", ExternalSoftwareRecord.sole.identifier
    assert_equal "pending", ExternalSoftwareRecord.sole.status
    assert_empty Project.all
    assert_requested request
  end

  test "weekly sweep resets a completed window and retains the saved page size" do
    import = ExternalSoftwareImport.start_open_alex(from: "2026-10-01", until_time: "2026-10-02", page_size: 2)
    import.update!(completed_at: 1.day.ago, pages_processed: 3, items_processed: 5, last_error: "old failure")
    assert_equal [{ "queued" => true }], scheduled_journal_tasks("open_alex:software", "harvest")
    state = JSON.parse(import.reload.cursor)
    assert_nil import.completed_at
    assert_nil state["from"]
    assert_equal Date.yesterday.iso8601, state["until"]
    assert_equal "*", state["token"]
    assert_nil state["last_id"]
    assert_equal 2, import.page_size
    assert_equal 0, import.items_processed
    assert_nil import.last_error
    assert_equal 1, ExternalSoftwareImport.count
  end

  test "weekly invocations preserve unfinished pages leases and retry times" do
    import = ExternalSoftwareImport.start_open_alex(page_size: 2)
    state = JSON.parse(import.cursor).merge("token" => "opaque/+==", "last_id" => "W100")
    import.update!(cursor: JSON.generate(state), pending_ids: ["W101"],
      pending_records: [{ "id" => "https://openalex.org/W101", "type" => "software" }],
      pending_next_cursor: "saved-next", page_retrieved_at: 1.minute.ago,
      next_run_at: 1.hour.from_now, lease_token: "current-lease", lease_expires_at: 10.minutes.from_now,
      last_error: "rate limited", pages_processed: 1, items_processed: 2)
    before = import.attributes
    2.times { scheduled_journal_tasks("open_alex:software", "harvest") }
    assert_equal before, import.reload.attributes
    assert_equal 1, ExternalSoftwareImport.count
    ImportOpenAlexSoftwareWorker.jobs.each { |job| assert_in_delta import.next_run_at.to_f, job.fetch("at"), 1 }
  end

  test "ten minute recovery queues only due imports and bounds metadata hydration" do
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .find { |entry| entry["command"] == "bundle exec rake open_alex:software:resume open_alex:software:refresh" }
    assert_equal "*/10 * * * *", cron.fetch("schedule")
    import = ExternalSoftwareImport.start_open_alex
    103.times do |index|
      ExternalSoftwareRecord.create!(source: "openalex", identifier: "W#{1000 + index}", next_refresh_at: 1.day.ago)
    end
    ExternalSoftwareRecord.create!(source: "openalex", identifier: "W2000", next_refresh_at: 1.day.from_now)
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "1010.083", next_refresh_at: 1.day.ago)
    assert_equal [{ "queued" => true }, { "queued" => 100 }], scheduled_journal_tasks("open_alex:software", "resume")
    assert_equal [[import.id]], ImportOpenAlexSoftwareWorker.jobs.pluck("args")
    batches = SyncOpenAlexSoftwareWorker.jobs.map { |job| job.fetch("args").sole }
    assert_equal [25, 25, 25, 25], batches.map(&:size)
    assert_equal 100, batches.flatten.uniq.size
    refute_includes batches.flatten, "W2000"
  end

  test "recovery respects leases backoff and completed sweeps without enabling new ones" do
    assert_equal [{ "queued" => false }, { "queued" => 0 }], scheduled_journal_tasks("open_alex:software", "resume")
    assert_empty ExternalSoftwareImport.all
    import = ExternalSoftwareImport.start_open_alex
    import.update!(next_run_at: 1.hour.from_now)
    assert_equal false, scheduled_journal_tasks("open_alex:software", "resume").first["queued"]
    import.update!(next_run_at: Time.current, lease_token: "claimed", lease_expires_at: 1.hour.from_now)
    assert_equal false, scheduled_journal_tasks("open_alex:software", "resume").first["queued"]
    import.update!(lease_token: nil, lease_expires_at: nil, completed_at: Time.current)
    assert_equal false, scheduled_journal_tasks("open_alex:software", "resume").first["queued"]
    assert_empty ImportOpenAlexSoftwareWorker.jobs
  end

  test "failed queue submission leaves a restarted sweep available for recovery" do
    import = ExternalSoftwareImport.start_open_alex
    import.update!(completed_at: 1.day.ago)
    ImportOpenAlexSoftwareWorker.stubs(:perform_at).raises(RedisClient::CannotConnectError)
    assert_raises(RedisClient::CannotConnectError) { scheduled_journal_tasks("open_alex:software", "harvest") }
    assert_nil import.reload.completed_at
    ImportOpenAlexSoftwareWorker.unstub(:perform_at)
    assert_equal true, scheduled_journal_tasks("open_alex:software", "resume").first["queued"]
    assert_equal [[import.id]], ImportOpenAlexSoftwareWorker.jobs.pluck("args")
  end
end
