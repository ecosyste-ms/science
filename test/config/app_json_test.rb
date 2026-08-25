require "test_helper"

class AppJsonTest < ActiveSupport::TestCase
  test "Brief scans are scheduled hourly in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    brief_crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:fetch_brief")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:fetch_brief LIMIT=50",
        "schedule" => "0 * * * *",
      },
    ], brief_crons
  end

  test "research organization domains are refreshed weekly" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("research_organizations:sync")
    end

    assert_equal [
      {
        "command" => "bundle exec rake research_organizations:sync",
        "schedule" => "0 4 * * 1",
      },
    ], crons
  end
end
