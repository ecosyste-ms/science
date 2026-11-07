require "test_helper"
require "rake"

class Jev::DatabaseSamplingTest < ActiveSupport::TestCase
  setup do
    @enabled = ENV["JEV_ENABLED"]
    ENV["JEV_ENABLED"] = "true"
  end

  teardown do
    @enabled ? ENV["JEV_ENABLED"] = @enabled : ENV.delete("JEV_ENABLED")
  end

  test "start task and scheduler traverse all score bands with a frozen resumable cursor" do
    projects = [0, 12, 80, nil].each_with_index.map do |score, index|
      Project.create!(url: "https://github.com/database/tool-#{index}", science_score: score)
    end
    before = projects.map(&:attributes)
    original = ENV.to_h.slice("NAME", "POPULATION", "TARGET", "BUDGET_USD")
    ENV["NAME"], ENV["POPULATION"], ENV["TARGET"], ENV["BUDGET_USD"] = "Database traversal", "database", "10", "0.1"
    Rails.application.load_tasks unless Rake::Task.task_defined?("jev:start")
    task = Rake::Task["jev:start"]
    task.reenable
    capture_io { task.invoke }
    run = Jev::Run.find_by!(name: "Database traversal")
    assert_equal true, run.settings["include_scored_projects"]
    assert_equal projects.last.id, run.sampling_state["database_ceiling"]
    run.update!(settings: run.settings.merge("batch_size" => 2))
    late = Project.create!(url: "https://github.com/database/late", science_score: 0)

    Jev::SchedulerWorker.new.perform
    assert_equal projects[1].id, run.reload.sampling_state["database_cursor"]
    assert_equal 2, run.sampling_state["database_examined"]
    refute run.sampling_complete?
    assert_equal 2, run.discoveries.count
    assert_equal ["queued_screen"], run.discoveries.distinct.pluck(:status)

    run.update!(status: "paused")
    Jev::SchedulerWorker.new.perform
    assert_equal 2, run.reload.sampling_state["database_examined"]
    run.update!(status: "running")
    Jev::SchedulerWorker.new.perform
    assert run.reload.sampling_complete?
    assert_equal 4, run.sampling_state["database_examined"]
    assert_equal 4, run.sampling_state["database_added"]
    assert_equal %w[score_included score_low score_unscored score_zero], run.discoveries.distinct.pluck(:sample_group).sort
    assert_equal ["database_primary_key_traversal"], run.discoveries.distinct.pluck(:sampling_method)
    refute run.discoveries.where(project: late).exists?
    assert_equal before, projects.map { |project| project.reload.attributes }
    Jev::SchedulerWorker.new.perform
    assert_equal 4, run.discoveries.count
  ensure
    original&.each { |key, value| ENV[key] = value }
    %w[NAME POPULATION TARGET BUDGET_USD].each { |key| ENV.delete(key) unless original&.key?(key) }
  end

  test "unsupported URLs and normalized duplicates advance the cursor while hidden records stay excluded" do
    first = Project.create!(url: "https://github.com/database/same", science_score: 0)
    Project.create!(url: "https://github.com/database/same.git", science_score: 50)
    Project.create!(url: "https://example.org/database/unsupported", science_score: 0)
    owner = Owner.create!(host: Host.find_or_create_by!(name: "GitHub"), login: "database-hidden")
    Project.create!(url: "https://github.com/database/hidden", science_score: 0, owner_record: owner)
    owner.update!(hidden: true)
    run = Jev::Run.start!(name: "Database exclusions", population: "database", target: 10, budget: "0.1")

    Jev::SchedulerWorker.new.perform
    assert run.reload.sampling_complete?
    assert run.sampling_state["frame_exhausted"]
    assert_equal 3, run.sampling_state["database_examined"]
    assert_equal 1, run.sampling_state["database_added"]
    assert_equal 1, run.sampling_state["database_duplicate_urls"]
    assert_equal 1, run.sampling_state["database_unsupported_urls"]
    assert_equal [first.id], run.discoveries.pluck(:project_id)
    assert_equal run.sampling_state, run.statistics[:sampling_state]
  end

  test "a failed seed batch rolls back candidates and cursor before retry" do
    3.times { |i| Project.create!(url: "https://github.com/database/retry-#{i}", science_score: 0) }
    run = Jev::Run.start!(name: "Database retry", population: "database", target: 2, budget: "0.1")
    sampler = Jev::Sampler.new(run)
    sampler.expects(:add).raises(Jev::Client::Error, "Interrupted batch")
    assert_raises(Jev::Client::Error) { sampler.seed }
    assert_equal 0, run.reload.sampling_state["database_cursor"]
    assert_equal 0, run.discoveries.count
    Jev::SchedulerWorker.new.perform
    assert run.reload.sampling_complete?
    refute run.sampling_state["frame_exhausted"]
    assert_equal 2, run.sampling_state["database_examined"]
    assert_equal 2, run.discoveries.count
  end
end
