require "test_helper"
require "rake"

class RescoreProjectsWorkerTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:rescore")
    Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
    RescoreProjectsWorker.jobs.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{RescoreProjectsWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
    Sidekiq.redis { |redis| redis.call("DEL", RescoreProjectsWorker::STATE_KEY) }
    JossVocabularyAnalyzer.stubs(:current_model).returns(nil)
  end

  teardown do
    RescoreProjectsWorker.jobs.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{RescoreProjectsWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
    Sidekiq.redis { |redis| redis.call("DEL", RescoreProjectsWorker::STATE_KEY) }
  end

  test "scheduled task refreshes stale and zero scores with stored evidence and normal callbacks" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "score-refresh")
    project = Project.create!(url: "https://github.com/score-refresh/research", host: host,
      owner_record: owner, science_score: 0, readme: "A scientific analysis implementation.")
    paper = Paper.create!(title: "Research methods", doi: "10.1234/methods")
    ProjectPaper.create!(project: project, paper: paper, role: "reference",
      evidence: [{ "source" => "citation", "url" => project.url }])
    project.update_columns(science_score: 0, science_score_breakdown: {})
    IndexSoftwareSearchWorker.jobs.clear

    capture_io { Rake::Task["projects:rescore"].execute }
    assert_equal 1, RescoreProjectsWorker.jobs.size
    RescoreProjectsWorker.perform_one

    assert_equal 20, project.reload.science_score
    assert project.science_score_breakdown.dig("breakdown", "has_resolved_paper", "present")
    assert_equal 1, owner.reload.projects_count
    assert_includes IndexSoftwareSearchWorker.jobs.map { |job| job["args"] }, [project.id]
    assert_equal project.id.to_s, state["after_id"]
  end

  test "cursor bounds batches and wraps to revisit changed evidence" do
    first = Project.create!(url: "https://example.org/first", science_score: nil)
    second = Project.create!(url: "https://example.org/second", science_score: 0)
    stub_const(RescoreProjectsWorker, :BATCH_SIZE, 1) do
      assert_equal 1, RescoreProjectsWorker.new.perform[:checked]
      assert_equal first.id.to_s, state["after_id"]
      assert_equal 0, first.reload.science_score
      assert_equal second.id, RescoreProjectsWorker.new.perform[:after_id]
      assert_equal 0, RescoreProjectsWorker.new.perform[:after_id]
      assert state["completed_at"]

      first.update!(readme: "https://doi.org/10.1234/new-evidence")
      RescoreProjectsWorker.new.perform
      assert_equal 20, first.reload.science_score
    end
  end

  test "unchanged results do not write projects or enqueue indexing" do
    project = Project.create!(url: "https://example.org/unchanged", readme: "https://doi.org/10.1234/example")
    project.update_science_score
    updated_at = project.reload.updated_at
    IndexSoftwareSearchWorker.jobs.clear
    result = nil

    travel 1.hour do
      result = RescoreProjectsWorker.new.perform
    end

    assert_equal 0, result[:updated]
    assert_equal updated_at, project.reload.updated_at
    assert_empty IndexSoftwareSearchWorker.jobs
  end

  test "hidden projects are excluded and failures do not block later projects" do
    first = Project.create!(url: "https://example.org/failure")
    last = Project.create!(url: "https://example.org/last", science_score: 0, readme: "https://doi.org/10.1234/example")
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "hidden")
    hidden = Project.create!(url: "https://example.org/hidden", owner_record: owner, science_score: 0)
    owner.update!(hidden: true)
    original = ScienceScoreCalculator.instance_method(:calculate)
    ScienceScoreCalculator.define_method(:calculate) do
      raise "bad evidence" if project.id == first.id
      original.bind_call(self)
    end

    result = RescoreProjectsWorker.new.perform

    assert_equal 1, result[:failed]
    assert_equal 2, result[:checked]
    assert_equal 20, last.reload.science_score
    assert_equal 0, hidden.reload.science_score
    assert_equal last.id.to_s, state["after_id"]
  ensure
    ScienceScoreCalculator.define_method(:calculate, original) if original
  end

  test "another running batch prevents concurrent progress" do
    config = Project.connection_db_config.configuration_hash
    connection = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username], password: config[:password])
    connection.exec("SELECT pg_advisory_lock(#{RescoreProjectsWorker::ADVISORY_LOCK})")

    assert_nil RescoreProjectsWorker.new.perform
    assert_empty state
  ensure
    connection&.close
  end

  def state
    Sidekiq.redis { |redis| redis.call("HGETALL", RescoreProjectsWorker::STATE_KEY) }.then { |value| value.is_a?(Hash) ? value : value.each_slice(2).to_h }
  end
end
