require "test_helper"
require "rake"

class OwnersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("owners:check_ror_repositories")
    Rake::Task["owners:check_ror_repositories"].reenable
    ENV.delete("LIMIT")
    SyncProjectWorker.jobs.clear

    create_research_organization_domain(
      "university.example",
      source: "ror",
      version: "owners",
      external_id: "https://ror.org/university"
    )
    create_research_organization_domain(
      "institute.example",
      source: "manual",
      version: "owners"
    )
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  teardown do
    ENV.delete("LIMIT")
    SyncProjectWorker.jobs.clear
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "checks due GitHub owners matched by ROR" do
    github = Host.create!(name: "GitHub")
    gitlab = Host.create!(name: "GitLab")
    due = Owner.create!(
      host: github,
      login: "university",
      kind: "organization",
      website: "https://university.example"
    )
    manual = Owner.create!(
      host: github,
      login: "institute",
      kind: "organization",
      website: "https://institute.example"
    )
    other_host = Owner.create!(
      host: gitlab,
      login: "university",
      kind: "organization",
      website: "https://university.example"
    )
    fresh = Owner.create!(
      host: github,
      login: "fresh-university",
      kind: "organization",
      website: "https://university.example",
      repositories_checked_at: 1.hour.ago
    )
    stub_request(
      :get,
      "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/university/repositories?page=1"
    ).to_return(
      status: 200,
      body: [{ html_url: "https://github.com/university/new-project" }].to_json
    )
    stub_request(
      :get,
      "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/university/repositories?page=2"
    ).to_return(status: 200, body: [].to_json)

    output, = capture_io { Rake::Task["owners:check_ror_repositories"].invoke }

    assert due.reload.repositories_checked_at.present?
    assert_nil manual.reload.repositories_checked_at
    assert_nil other_host.reload.repositories_checked_at
    assert_in_delta 1.hour.ago, fresh.reload.repositories_checked_at, 1.second
    assert Project.exists?(url: "https://github.com/university/new-project")
    assert_equal 1, SyncProjectWorker.jobs.size
    assert_includes output, "Checked repositories for 1 ROR owners"
  end

  test "rejects a non-positive limit" do
    ENV["LIMIT"] = "0"

    assert_raises(SystemExit) do
      capture_io { Rake::Task["owners:check_ror_repositories"].invoke }
    end
  end
end
