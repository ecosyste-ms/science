require "test_helper"
require "rake"
require_relative "../support/swhid_pipeline"

class SwhidApiQueueMigrationTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    prefix = "science:test:queue-move:#{SecureRandom.hex(8)}"
    @source = "#{prefix}:source"
    @destination = "#{prefix}:destination"
    @scheduled = "#{prefix}:schedule"
    @retries = "#{prefix}:retry"
    migration = SwhidApiQueueMigration.new(source: @source, destination: @destination,
      scheduled: @scheduled, retries: @retries)
    SwhidApiQueueMigration.stubs(:new).returns(migration)
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:move_api_jobs")
    @previous_dry_run = ENV.delete("DRY_RUN")
  end

  teardown do
    @previous_dry_run ? ENV["DRY_RUN"] = @previous_dry_run : ENV.delete("DRY_RUN")
    Sidekiq.redis do |redis|
      redis.call("DEL", "queue:#{@source}", "queue:#{@destination}", @scheduled, @retries)
      redis.call("SREM", "queues", @source, @destination)
    end
  end

  test "task previews then moves API jobs in execution order while preserving scans and metadata" do
    enqueue(FetchSwhidWorker, [101])
    enqueue(CheckSwhidArchivalWorker, [102])
    enqueue(CheckSwhidOriginWorker, [103, true])
    enqueue(CheckSwhidBatchWorker)
    original = Sidekiq::Queue.new(@source).to_a.map(&:item)

    assert_equal 3, run_task.fetch("queued")
    assert_equal original, Sidekiq::Queue.new(@source).to_a.map(&:item)
    assert_equal 0, Sidekiq::Queue.new(@destination).size

    result = run_task(dry_run: false)

    assert_equal false, result.fetch("dry_run")
    assert_equal 3, result.fetch("queued")
    assert_equal ["FetchSwhidWorker"], Sidekiq::Queue.new(@source).map(&:klass)
    moved = Sidekiq::Queue.new(@destination).map(&:item)
    expected = original.reject { |job| job["class"] == "FetchSwhidWorker" }
      .map { |job| job.merge("queue" => @destination) }
    assert_equal expected.map { |job| job.except("lock_digest") }, moved.map { |job| job.except("lock_digest") }
    assert_equal 0, run_task(dry_run: false).fetch("queued")
  end

  test "scheduled and retry jobs retain their times and error metadata" do
    enqueue(CheckSwhidOriginWorker, [104])
    origin = Sidekiq::Queue.new(@source).first.item
    Sidekiq::Queue.new(@source).first.delete
    scheduled = Sidekiq::JobSet.new(@scheduled)
    retries = Sidekiq::JobSet.new(@retries)
    scheduled.schedule(1.hour.from_now, origin)
    retry_job = origin.merge("class" => "CheckSwhidArchivalWorker", "jid" => SecureRandom.hex(12),
      "retry_count" => 2, "error_class" => "RuntimeError", "error_message" => "HTTP failure")
    retries.schedule(2.hours.from_now, retry_job)
    unrelated = origin.merge("queue" => "another_queue", "jid" => SecureRandom.hex(12))
    scheduled.schedule(3.hours.from_now, unrelated)
    scan = origin.merge("class" => "FetchSwhidWorker", "jid" => SecureRandom.hex(12))
    retries.schedule(4.hours.from_now, scan)
    before = [scheduled, retries].map { |set| set.to_a.map { |job| [job.score, job.item] } }

    preview = run_task
    assert_equal 1, preview.fetch("scheduled")
    assert_equal 1, preview.fetch("retries")
    assert_equal before, [scheduled, retries].map { |set| set.to_a.map { |job| [job.score, job.item] } }

    result = run_task(dry_run: false)
    assert_equal 1, result.fetch("scheduled")
    assert_equal 1, result.fetch("retries")
    expected = before.map do |entries|
      entries.map do |score, job|
        move = job["queue"] == @source && job["class"] != "FetchSwhidWorker"
        [score, move ? job.merge("queue" => @destination) : job]
      end
    end
    assert_equal expected.map { |entries| entries.map { |score, job| [score, job.except("lock_digest")] } },
      [scheduled, retries].map { |set| set.to_a.map { |job| [job.score, job.item.except("lock_digest")] } }
    assert_equal 0, run_task(dry_run: false).fetch("scheduled")
    assert_equal 0, run_task(dry_run: false).fetch("retries")
  end

  test "a moved unique job holds the destination lock and releases the source lock" do
    jid = enqueue(CheckSwhidBatchWorker)
    assert_nil enqueue(CheckSwhidBatchWorker)

    run_task(dry_run: false)
    assert enqueue(CheckSwhidBatchWorker)
    assert_nil Sidekiq::Testing.disable! { CheckSwhidBatchWorker.set(queue: @destination).perform_async }
    raw = Sidekiq.redis { |redis| redis.call("RPOP", "queue:#{@destination}") }
    job = Sidekiq.load_json(raw)
    assert_equal jid, job.fetch("jid")
    CheckSwhidBatchWorker.process_job(job)

    assert Sidekiq::Testing.disable! { CheckSwhidBatchWorker.set(queue: @destination).perform_async }
  end

  test "jobs claimed by another worker are not recreated" do
    enqueue(CheckSwhidArchivalWorker, [105])
    job = Sidekiq::Queue.new(@source).first
    job.delete
    Sidekiq::Queue.any_instance.stubs(:select).returns([job])

    assert_equal 0, run_task(dry_run: false).fetch("queued")
    assert_equal 0, Sidekiq::Queue.new(@destination).size
  end

  test "a destination lock conflict leaves the original job and lock intact" do
    enqueue(CheckSwhidBatchWorker)
    Sidekiq::Testing.disable! { CheckSwhidBatchWorker.set(queue: @destination).perform_async }

    result = run_task(dry_run: false)

    assert_equal 0, result.fetch("queued")
    assert_equal 1, result.fetch("lock_conflicts")
    assert_equal 1, Sidekiq::Queue.new(@source).size
    assert_equal 1, Sidekiq::Queue.new(@destination).size
    assert_nil enqueue(CheckSwhidBatchWorker)
  end

  test "a claimed unique job releases the unused destination lock" do
    enqueue(CheckSwhidBatchWorker)
    job = Sidekiq::Queue.new(@source).first
    job.delete
    Sidekiq::Queue.any_instance.stubs(:select).returns([job])

    assert_equal 0, run_task(dry_run: false).fetch("queued")
    assert Sidekiq::Testing.disable! { CheckSwhidBatchWorker.set(queue: @destination).perform_async }
  end

  test "task rejects an invalid dry run option before moving jobs" do
    enqueue(CheckSwhidArchivalWorker, [106])
    assert_raises(ArgumentError) { run_task(dry_run: "no") }
    assert_equal 1, Sidekiq::Queue.new(@source).size
  end

  test "task permits previews but refuses to move jobs while relevant workers are registered" do
    enqueue(CheckSwhidArchivalWorker, [107])
    Sidekiq::ProcessSet.stubs(:new).returns([{ "queues" => [@source] }])

    assert_equal 1, run_task.fetch("queued")
    error = assert_raises(RuntimeError) { run_task(dry_run: false) }
    assert_match "Stop workers", error.message
    assert_equal 1, Sidekiq::Queue.new(@source).size
    assert_equal 0, Sidekiq::Queue.new(@destination).size
  end

  def enqueue(worker, args = [])
    Sidekiq::Testing.disable! { worker.set(queue: @source).perform_async(*args) }
  end

  def run_task(dry_run: nil)
    ENV["DRY_RUN"] = dry_run.to_s unless dry_run.nil?
    Rake::Task["swhids:move_api_jobs"].reenable
    output, = capture_io { Rake::Task["swhids:move_api_jobs"].invoke }
    JSON.parse(output)
  end
end
