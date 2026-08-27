require "test_helper"

class AppJsonTest < ActiveSupport::TestCase
  test "cron commands do not set environment variables" do
    config = JSON.parse(Rails.root.join("app.json").read)

    config.fetch("cron").each do |cron|
      assert_no_match(/\b[A-Z][A-Z0-9_]*=/, cron.fetch("command"))
    end
  end

  test "Brief scans are scheduled every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    brief_crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:fetch_brief")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:fetch_brief",
        "schedule" => "*/10 * * * *",
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

  test "homepage stats are refreshed hourly" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("homepage:refresh")
    end

    assert_equal [
      {
        "command" => "bundle exec rake homepage:refresh",
        "schedule" => "5 * * * *",
      },
    ], crons
  end

  test "ROR owner repositories are checked hourly in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("owners:check_ror_repositories")
    end

    assert_equal [
      {
        "command" => "bundle exec rake owners:check_ror_repositories",
        "schedule" => "15 * * * *",
      },
    ], crons
  end

  test "OpenAlex topics are refreshed daily" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("open_alex:sync")
    end

    assert_equal [
      {
        "command" => "bundle exec rake open_alex:sync",
        "schedule" => "0 5 * * *",
      },
    ], crons
  end
end
