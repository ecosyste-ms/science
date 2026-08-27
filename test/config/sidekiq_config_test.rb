require "test_helper"

class SidekiqConfigTest < ActiveSupport::TestCase
  test "tests use Sidekiq's supported fake queue API" do
    assert Sidekiq::Testing.fake?
    assert_not $LOADED_FEATURES.any? { |feature| feature.end_with?("/sidekiq/testing.rb") }
  end

  test "the worker uses bounded concurrency and weighted queues" do
    config = YAML.safe_load_file(
      Rails.root.join("config/sidekiq.yml"),
      permitted_classes: [Symbol]
    )

    assert_equal 10, config[:concurrency]
    assert_equal [["default", 5], ["brief", 1]], config[:queues]
  end

  test "the Procfile starts one Sidekiq process" do
    sidekiq_processes = Rails.root.join("Procfile").readlines(chomp: true).grep(/sidekiq/)

    assert_equal ["worker: bundle exec sidekiq -C config/sidekiq.yml"], sidekiq_processes
  end
end
