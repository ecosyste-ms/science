require "test_helper"
require "rake"
require_relative "../support/journal_schedule"

class ExternalProjectSyncSchedulingTest < ActiveSupport::TestCase
  include JournalSchedule

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("external_software:sync")
    SyncExternalProjectWorker.clear
    clear_locks
  end

  teardown do
    SyncExternalProjectWorker.clear
    clear_locks
  end

  def clear_locks
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncExternalProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def requests(count, error: nil, due_at: 10.days.ago)
    Array.new(count) do
      project = Project.create!(url: "https://github.com/sync-test/#{SecureRandom.hex(8)}")
      ExternalProjectSync.create!(project: project, requested_at: 10.days.ago,
        next_attempt_at: due_at, last_error: error)
    end
  end

  test "five minute schedule reserves retry capacity without waiting for discovery" do
    fresh = requests(100)
    failed = requests(25, error: "old schema", due_at: 1.day.ago)
    leased = requests(1, error: "leased").sole
    leased.update!(lease_expires_at: 1.hour.from_now)
    requests(1, error: "backoff", due_at: 1.hour.from_now)
    completed = requests(1).sole
    completed.update!(completed_at: completed.requested_at)

    DiscoverExternalRepositoriesWorker.expects(:perform_async).never
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .find { |entry| entry["command"] == "bundle exec rake external_software:sync" }
    assert_equal "*/5 * * * *", cron.fetch("schedule")
    assert_equal [{ "project_syncs" => 100, "limit" => 100 }], scheduled_journal_tasks("external_software", "sync")
    ids = SyncExternalProjectWorker.jobs.map { |job| job.fetch("args").sole }
    assert_equal failed.first(20).map(&:id) + fresh.first(80).map(&:id), ids
    assert_equal [{ "project_syncs" => 0, "limit" => 100 }], scheduled_journal_tasks("external_software", "sync")
    assert_equal 100, SyncExternalProjectWorker.jobs.size
  end

  test "unused retry capacity fills from ordinary requests" do
    fresh = requests(100)
    retry_request = requests(1, error: "timeout", due_at: 1.day.ago).sole
    scheduled_journal_tasks("external_software", "sync")
    ids = SyncExternalProjectWorker.jobs.map { |job| job.fetch("args").sole }
    assert_equal [retry_request.id] + fresh.first(99).map(&:id), ids
  end

  test "retries fill the batch when no ordinary requests remain" do
    failed = requests(105, error: "timeout")
    scheduled_journal_tasks("external_software", "sync")
    assert_equal failed.first(100).map(&:id), SyncExternalProjectWorker.jobs.map { |job| job.fetch("args").sole }
  end

  test "small limits remain bounded and invalid limits cannot enqueue" do
    requests(2)
    failed = requests(2, error: "timeout", due_at: 1.day.ago)
    ENV["LIMIT"] = "1"
    assert_equal [{ "project_syncs" => 1, "limit" => 1 }], scheduled_journal_tasks("external_software", "sync")
    assert_equal [failed.first.id], SyncExternalProjectWorker.jobs.sole.fetch("args")
    %w[0 101 invalid].each do |limit|
      ENV["LIMIT"] = limit
      assert_raises(ArgumentError) { scheduled_journal_tasks("external_software", "sync") }
    end
  ensure
    ENV.delete("LIMIT")
  end
end
