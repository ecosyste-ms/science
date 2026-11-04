require "test_helper"
require "rake"
require_relative "../support/journal_schedule"

class OpenAlexSoftwareSchedulingTest < ActiveSupport::TestCase
  include JournalSchedule

  setup do
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
