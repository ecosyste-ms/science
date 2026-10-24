require "test_helper"
require "rake"
require_relative "../support/swhid_pipeline"

class SwhidEnqueueTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:enqueue")
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Sidekiq.redis { |redis| redis.call("DEL", SwhidEnqueuer::CURSORS_KEY) }
    CheckSwhidArchivalWorker.clear
  end

  teardown do
    Sidekiq.redis { |redis| redis.call("DEL", SwhidEnqueuer::CURSORS_KEY) }
    CheckSwhidArchivalWorker.clear
  end

  test "scheduled task recovers stale checks without syncing or cloning the project" do
    project = create_project("stale", archive: { "status" => "error", "error" => "HTTP 403", "attempted_at" => 2.hours.ago.iso8601 })
    unchanged_sync = project.last_synced_at
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .with(body: [project.swhids.dig("revision", "swhid")].to_json)
      .to_return(body: { project.swhids.dig("revision", "swhid") => { known: true } }.to_json)
    ProjectSwhidScanner.expects(:new).never

    assert_equal({ "scans" => 0, "scan_retries" => 0, "checks" => 1, "archival" => 0 }, enqueue)
    CheckSwhidBatchWorker.perform_one

    assert_equal "archived", project.reload.swhids.dig("revision", "archive", "status")
    assert_nil project.swhids.dig("revision", "archive", "error")
    assert_equal unchanged_sync, project.last_synced_at
    assert_requested request, times: 1
    assert_empty RepositoryScanWorker.jobs
  end

  test "checks respect the error cooldown, refresh interval and rate limit deadline" do
    create_project("fresh", archive: { "status" => "archived", "checked_at" => 1.day.ago.iso8601 })
    create_project("recent-error", archive: { "status" => "error", "attempted_at" => 30.minutes.ago.iso8601 })
    create_project("rate-limited", archive: { "status" => "error", "attempted_at" => 2.hours.ago.iso8601, "retry_at" => 1.hour.from_now.iso8601 })
    stale = create_project("old-check", archive: { "status" => "archived", "checked_at" => 8.days.ago.iso8601 })
    missing = create_project("no-check")

    assert_equal 2, enqueue.fetch("checks")
    assert_equal [stale.id.to_s, missing.id.to_s], pending_ids
    assert_empty RepositoryScanWorker.jobs
  end

  test "scan selection includes newly scientific projects and cooled down errors but preserves archival evidence" do
    newly_eligible = Project.create!(url: "https://github.com/enqueue/new", science_score: 0, repository: {})
    newly_eligible.update!(science_score: 42)
    retrying = Project.create!(url: "https://github.com/enqueue/retry", science_score: 42, repository: {}, swhids: {
      "status" => "error", "error" => "command timed out", "attempted_at" => 2.days.ago.iso8601
    })
    Project.create!(url: "https://github.com/enqueue/recent", science_score: 42, repository: {}, swhids: {
      "status" => "error", "attempted_at" => 1.hour.ago.iso8601
    })
    Project.create!(url: "https://github.com/enqueue/large", science_score: 42, repository: {}, swhids: {
      "status" => "error", "error" => RepositoryCheckout::DISK_LIMIT_ERROR, "attempted_at" => 2.days.ago.iso8601
    })
    Project.create!(url: "https://github.com/enqueue/evidence", science_score: 42, repository: {}, swhids: {
      "status" => "error", "attempted_at" => 2.days.ago.iso8601, "archival" => { "status" => "completed", "id" => 123 }
    })

    counts = enqueue

    assert_equal 1, counts.fetch("scans")
    assert_equal 1, counts.fetch("scan_retries")
    assert_equal [[newly_eligible.id], [retrying.id]], RepositoryScanWorker.jobs.pluck("args")
    assert retrying.reload.swhid_scan_due?
  end

  test "independent limits and cursors advance past work already queued and wrap around" do
    projects = 2.times.map { |i| create_project("page-#{i}") }
    poll = create_project("poll", archive: { "status" => "archived", "checked_at" => Time.current.iso8601 })
    poll.update!(swhids: poll.swhids.merge("archival" => pending_request))

    first = enqueue("CHECK_LIMIT" => "1", "ARCHIVAL_LIMIT" => "1")
    second = enqueue("CHECK_LIMIT" => "1", "ARCHIVAL_LIMIT" => "1")

    assert_equal 1, first.fetch("checks")
    assert_equal 1, first.fetch("archival")
    assert_equal 1, second.fetch("checks")
    assert_equal projects.map { |project| project.id.to_s }, pending_ids
    Sidekiq.redis { |redis| redis.call("DEL", CheckSwhidBatchWorker::PENDING_KEY) }
    assert_equal 1, enqueue("CHECK_LIMIT" => "1").fetch("checks")
    assert_equal [projects.first.id.to_s], pending_ids
  end

  test "due archival requests recover through their worker and retain existing request IDs" do
    project = create_project("pending", archive: { "status" => "archived", "checked_at" => Time.current.iso8601 })
    project.update!(swhids: project.swhids.merge("archival" => pending_request.merge("error" => "HTTP 403")))
    request = stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(body: {
      id: 123, origin_url: project.url, visit_type: "git", save_request_date: 1.day.ago.iso8601,
      save_request_status: "accepted", save_task_status: "scheduled"
    }.to_json)

    assert_equal 1, enqueue.fetch("archival")
    CheckSwhidArchivalWorker.perform_one

    assert_equal 123, project.reload.swhids.dig("archival", "id")
    assert_nil project.swhids.dig("archival", "error")
    assert_requested request, times: 1
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end

  test "missing objects with fresh checks queue their first archival submission" do
    project = create_project("missing", archive: { "status" => "not_found", "checked_at" => Time.current.iso8601 })

    assert_equal 1, enqueue.fetch("archival")
    assert_equal [[project.id]], CheckSwhidArchivalWorker.jobs.pluck("args")
    assert_empty CheckSwhidBatchWorker.jobs
  end

  test "future polls and terminal or uncertain submissions are left alone" do
    %w[pending completed failed rejected expired uncertain].each do |status|
      project = create_project(status, archive: { "status" => "archived", "checked_at" => Time.current.iso8601 })
      request = pending_request.merge("status" => status)
      request["next_check_at"] = 1.hour.from_now.iso8601 if status == "pending"
      project.update!(swhids: project.swhids.merge("archival" => request))
    end

    assert_equal 0, enqueue.fetch("archival")
    assert_empty CheckSwhidArchivalWorker.jobs
  end

  test "gated, hidden, unscientific and metadata-less projects are excluded" do
    gated = create_project("gated")
    gated.update!(repository: { "gated" => true })
    unscientific = create_project("unscientific")
    unscientific.update!(science_score: 0)
    missing_metadata = create_project("metadata")
    missing_metadata.update!(repository: nil)
    hidden = create_project("hidden")
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "enqueue")
    hidden.update!(owner_record: owner)
    owner.update!(hidden: true)

    assert_equal({ "scans" => 0, "scan_retries" => 0, "checks" => 0, "archival" => 0 }, enqueue)
    assert_empty RepositoryScanWorker.jobs
    assert_empty CheckSwhidBatchWorker.jobs
  end

  test "shared API cooldown allows scans while leaving API work deferred" do
    Project.create!(url: "https://github.com/enqueue/scan", science_score: 42, repository: {})
    create_project("check")
    Rails.cache.write(SwhidApi::COOLDOWN_KEY, 1.hour.from_now.to_f)

    assert_equal({ "scans" => 1, "scan_retries" => 0, "checks" => 0, "archival" => 0 }, enqueue)
    assert_empty CheckSwhidBatchWorker.jobs
    assert_empty CheckSwhidArchivalWorker.jobs
  end

  test "orphaned pending IDs restart the batch even when coverage is fresh" do
    project = create_project("orphan", archive: { "status" => "archived", "checked_at" => Time.current.iso8601 })
    Sidekiq.redis { |redis| redis.call("ZADD", CheckSwhidBatchWorker::PENDING_KEY, Time.current.to_f, project.id) }

    assert_equal 0, enqueue.fetch("checks")
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    CheckSwhidBatchWorker.perform_one
    assert_empty pending_ids
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  test "task rejects unbounded limits" do
    %w[SCAN_LIMIT CHECK_LIMIT ARCHIVAL_LIMIT].each do |name|
      assert_raises(ArgumentError) { enqueue(name => "0") }
      assert_raises(ArgumentError) { enqueue(name => "1001") }
    end
    assert_empty RepositoryScanWorker.jobs
  end

  def create_project(name, archive: nil)
    Project.create!(url: "https://github.com/enqueue/#{name}", science_score: 42, repository: {}, last_synced_at: 10.days.ago,
      swhids: { "status" => "success", "origin" => "https://github.com/enqueue/#{name}",
        "revision" => { "status" => "success", "swhid" => "swh:1:rev:#{Digest::SHA1.hexdigest(name)}", "archive" => archive }.compact })
  end

  def pending_request
    { "status" => "pending", "id" => 123, "origin" => "https://github.com/enqueue/pending",
      "attempted_at" => 1.day.ago.iso8601, "next_check_at" => 1.hour.ago.iso8601 }
  end

  def enqueue(values = {})
    previous = ENV.to_h.slice("SCAN_LIMIT", "CHECK_LIMIT", "ARCHIVAL_LIMIT")
    ENV.update("SCAN_LIMIT" => "5", "CHECK_LIMIT" => "500", "ARCHIVAL_LIMIT" => "100")
    ENV.update(values)
    Rake::Task["swhids:enqueue"].reenable
    output, = capture_io { Rake::Task["swhids:enqueue"].invoke }
    JSON.parse(output)
  ensure
    %w[SCAN_LIMIT CHECK_LIMIT ARCHIVAL_LIMIT].each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  def pending_ids
    Sidekiq.redis { |redis| redis.call("ZRANGE", CheckSwhidBatchWorker::PENDING_KEY, 0, -1) }
  end
end
