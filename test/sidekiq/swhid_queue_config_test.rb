require "test_helper"
require "sidekiq/cli"
require_relative "../support/swhid_pipeline"

class SwhidQueueConfigTest < ActiveSupport::TestCase
  include SwhidPipeline

  test "worker startup reserves an API thread within the existing concurrency" do
    cli = Sidekiq::CLI.new
    cli.config = Sidekiq::Config.new
    cli.parse(["-C", Rails.root.join("config/sidekiq.yml").to_s, "-e", "test"])

    assert_equal 10, cli.config.total_concurrency
    assert_equal 9, cli.config.default_capsule.concurrency
    assert_equal({ "default" => 5, "brief" => 1, "swhid" => 1 }, cli.config.default_capsule.weights)
    api = cli.config.capsules.fetch("swh_api")
    assert_equal 1, api.concurrency
    assert_equal ["swh_api"], api.queues
  end

  test "API jobs enqueue separately from repository scans" do
    Sidekiq::Testing.fake! do
      [CheckSwhidBatchWorker, CheckSwhidOriginWorker, CheckSwhidArchivalWorker, FetchSwhidWorker].each do |worker|
        args = worker == CheckSwhidBatchWorker ? [] : [123]
        worker.perform_async(*args)
        assert_equal(worker == FetchSwhidWorker ? "swhid" : "swh_api", worker.jobs.last.fetch("queue"))
      end
    end
  ensure
    [CheckSwhidBatchWorker, CheckSwhidOriginWorker, CheckSwhidArchivalWorker, FetchSwhidWorker].each(&:clear)
  end
end
