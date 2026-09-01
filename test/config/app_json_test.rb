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

  test "project dependencies are indexed every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    dependency_crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:sync_dependencies")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:sync_dependencies",
        "schedule" => "3,13,23,33,43,53 * * * *",
      },
    ], dependency_crons
  end

  test "CFF authors are indexed every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:sync_citation_authors")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:sync_citation_authors",
        "schedule" => "1,11,21,31,41,51 * * * *",
      },
    ], crons
  end

  test "project contributors are indexed every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:sync_contributors")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:sync_contributors",
        "schedule" => "5,15,25,35,45,55 * * * *",
      },
    ], crons
  end

  test "author identities are linked every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:sync_author_identities")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:sync_author_identities",
        "schedule" => "0,10,20,30,40,50 * * * *",
      },
    ], crons
  end

  test "stale zero-score package projects are refreshed in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("packages:refresh_projects")
    end

    assert_equal [
      {
        "command" => "bundle exec rake packages:refresh_projects",
        "schedule" => "2,12,22,32,42,52 * * * *",
      },
    ], crons
  end

  test "project dependencies are resolved to packages after indexing" do
    config = JSON.parse(Rails.root.join("app.json").read)
    resolution_crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("packages:resolve_dependencies")
    end

    assert_equal [
      {
        "command" => "bundle exec rake packages:resolve_dependencies",
        "schedule" => "6,16,26,36,46,56 * * * *",
      },
    ], resolution_crons
  end

  test "package rankings are normalized every ten minutes in bounded batches" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("packages:normalize_rankings")
    end

    assert_equal [
      {
        "command" => "bundle exec rake packages:normalize_rankings",
        "schedule" => "4,14,24,34,44,54 * * * *",
      },
    ], crons
  end

  test "package registries are refreshed before dependency resolution" do
    config = JSON.parse(Rails.root.join("app.json").read)
    registry_crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("packages:sync_registries")
    end

    assert_equal [
      {
        "command" => "bundle exec rake packages:sync_registries",
        "schedule" => "0 2 * * *",
      },
    ], registry_crons
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

  test "OpenAlex field classifications are rebuilt after the topic sync" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("open_alex:classify_fields")
    end

    assert_equal [
      {
        "command" => "bundle exec rake open_alex:classify_fields",
        "schedule" => "0 6 * * *",
      },
    ], crons
  end

  test "metadata repositories are imported daily" do
    config = JSON.parse(Rails.root.join("app.json").read)
    crons = config.fetch("cron").select do |cron|
      cron.fetch("command").include?("projects:import_metadata_repositories")
    end

    assert_equal [
      {
        "command" => "bundle exec rake projects:import_metadata_repositories",
        "schedule" => "0 1 * * *",
      },
    ], crons
  end
end
