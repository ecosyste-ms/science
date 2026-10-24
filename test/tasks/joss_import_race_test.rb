require "test_helper"
require "rake"

class JossImportRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:import_joss")
    @urls = []
    SyncProjectWorker.jobs.clear
  end

  teardown do
    Project.where(url: @urls).destroy_all
    SyncProjectWorker.jobs.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{SyncProjectWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  %i[validation create].each do |stage|
    test "import_joss reuses a project inserted before #{stage} and continues importing" do
      url = "https://github.com/test/joss-race-#{stage}"
      next_url = "https://github.com/test/joss-after-race-#{stage}"
      @urls = [url, next_url]
      papers = [
        { software_repository: url, title: "Concurrent JOSS paper", year: 2026 },
        { software_repository: next_url, title: "Next JOSS paper", year: 2026 }
      ]
      stub_request(:get, "https://joss.theoj.org/papers/published.json?page=1")
        .to_return(status: 200, body: papers.to_json)
      stub_request(:get, "https://joss.theoj.org/papers/published.json?page=2")
        .to_return(status: 200, body: [].to_json)

      importer_thread = Thread.current
      concurrent_project = nil
      callback = lambda do |project|
        next unless Thread.current == importer_thread && project.new_record? && project.url == url
        next if concurrent_project

        concurrent_project = Thread.new do
          Project.connection_pool.with_connection do
            Project.create!(url: url, name: "Existing name", science_score: 0)
          end
        end.value
      end
      Project.set_callback(stage, :before, callback)

      output, = capture_io { Rake::Task["projects:import_joss"].execute }

      assert_equal 1, Project.where(url: url).count
      assert_equal "Concurrent JOSS paper", concurrent_project.reload.joss_metadata.fetch("title")
      assert_equal "Existing name", concurrent_project.name
      assert_operator concurrent_project.science_score, :>=, 85
      assert_equal "Next JOSS paper", Project.find_by!(url: next_url).joss_metadata.fetch("title")
      assert_equal [[Project.find_by!(url: next_url).id]], SyncProjectWorker.jobs.map { |job| job["args"] }
      assert_includes output, "Total new projects created: 1"
      assert_includes output, "Total existing projects found: 1"
    ensure
      Project.skip_callback(stage, :before, callback) if callback
    end
  end
end
