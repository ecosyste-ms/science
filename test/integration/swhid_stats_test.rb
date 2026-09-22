require "test_helper"
require "rake"

class SwhidStatsTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:refresh")
    Rake::Task["swhids:refresh"].reenable
    Sidekiq.redis { |redis| redis.call("DEL", SwhidStats::KEY) }
  end

  teardown do
    Sidekiq.redis { |redis| redis.call("DEL", SwhidStats::KEY) }
  end

  test "scheduled refresh publishes project coverage and distinct contributions to HTML and JSON" do
    revision = "swh:1:rev:#{'a' * 40}"
    directory = "swh:1:dir:#{'b' * 40}"
    project = Project.create!(url: "https://github.com/example/archived", repository: {}, science_score: 42,
      swhids: {
        "origin_archive" => { "status" => "archived" },
        "archival" => {
          "id" => 123, "status" => "completed", "attribution_eligible" => true,
          "save_task_status" => "succeeded", "confirmed_swhids" => [revision, directory],
          "repository_before_request" => { "classification" => "missing_versions", "basis" => "pre_submission" }
        }
      })
    Project.create!(url: "https://github.com/example/excluded", repository: {}, science_score: 0,
      swhids: project.swhids.deep_merge("archival" => { "confirmed_swhids" => [revision, "swh:1:rev:#{'c' * 40}"] }))
    Project.create!(url: "https://github.com/example/unchecked", repository: {}, science_score: 42)

    freeze_time do
      output, = capture_io { Rake::Task["swhids:refresh"].invoke }
      assert_includes output, "Stored SWHID stats for 2 eligible projects"
      snapshot = SwhidStats.read
      assert_equal(-1, Sidekiq.redis { |redis| redis.call("TTL", SwhidStats::KEY) })
      Rails.cache.clear
      assert_equal Time.current.iso8601, snapshot.fetch("updated_at")
      assert_equal 2, snapshot.fetch("eligible_projects")
      assert_equal({ "archived" => 1, "not_found" => 0, "unknown" => 0, "unchecked" => 1 }, snapshot.fetch("repository_coverage"))
      assert_equal({ "missing_versions" => 1, "missing_repository" => 0, "unknown" => 0 }, snapshot.fetch("submitted_projects"))
      assert_equal snapshot.fetch("submitted_projects"), snapshot.fetch("imported_projects")
      assert_equal({ "pre_submission" => 1 }, snapshot.fetch("submission_evidence"))
      assert_equal({ "total" => 3, "revisions" => 2, "directories" => 1 }, snapshot.fetch("contributions"))

      project.update!(science_score: 0)
      SwhidCoverageReport.expects(:counts).never
      SwhidArchiver.expects(:contribution_counts).never

      travel 2.days
      queries = []
      ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
        get swhids_path
        assert_response :success
        assert_select "h1", "SWHID stats"
        assert_select "time[datetime='#{snapshot.fetch('updated_at')}']"
        assert_select "dd", text: "1/2 (50.0%)", count: 2
        assert_select "dd", text: "3"
        assert_select "a[href='#{api_v1_swhids_path}']", text: "JSON API"
        assert_select "td", text: "0"

        get api_v1_swhids_path
        assert_response :success
        assert_equal "application/json", response.media_type
        assert_equal snapshot, response.parsed_body
      end
      assert_empty queries
    end
    assert_not_requested :any, /archive\.softwareheritage\.org/
  end

  test "missing snapshot returns unavailable without calculating stats or querying projects" do
    SwhidCoverageReport.expects(:counts).never
    SwhidArchiver.expects(:contribution_counts).never
    Project.expects(:with_connection).never

    get swhids_path
    assert_response :service_unavailable
    assert_select "p", text: /SWHID stats are not available yet/
    assert_select "table", count: 0

    get api_v1_swhids_path
    assert_response :service_unavailable
    assert_equal({ "error" => "SWHID stats are not available yet" }, response.parsed_body)
    assert_nil SwhidStats.read
  end

  test "refresh with no projects publishes zero counts" do
    capture_io { Rake::Task["swhids:refresh"].invoke }

    get swhids_path
    assert_response :success
    assert_select "dd", text: "0/0 (n/a)", count: 2

    get api_v1_swhids_path
    assert_response :success
    assert_equal 0, response.parsed_body.fetch("eligible_projects")
    assert_equal({ "total" => 0, "revisions" => 0, "directories" => 0 }, response.parsed_body.fetch("contributions"))
  end

  test "failed calculation preserves the previous snapshot" do
    Sidekiq.redis { |redis| redis.call("SET", SwhidStats::KEY, JSON.generate("updated_at" => "previous")) }
    SwhidArchiver.expects(:contribution_counts).raises(StandardError, "query failed")

    assert_raises(StandardError) { Rake::Task["swhids:refresh"].invoke }

    assert_equal({ "updated_at" => "previous" }, SwhidStats.read)
  end

  test "failed Redis write fails the scheduled task" do
    redis = mock
    redis.expects(:call).with("SET", SwhidStats::KEY, anything).returns(nil)
    Sidekiq.stubs(:redis).yields(redis)

    error = assert_raises(RuntimeError) { Rake::Task["swhids:refresh"].invoke }

    assert_equal "Failed to store SWHID stats", error.message
  ensure
    Sidekiq.unstub(:redis)
  end
end
