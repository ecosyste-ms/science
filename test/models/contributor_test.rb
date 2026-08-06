require "test_helper"

class ContributorTest < ActiveSupport::TestCase
  test "visible excludes contributors matching a hidden owner" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "hidden-user", hidden: true)
    hidden_contributor = Contributor.create!(
      login: "HIDDEN-USER",
      email: "hidden@example.com"
    )
    hidden_profile_contributor = Contributor.create!(
      email: "profile@example.com",
      profile: { "login" => "hidden-user" }
    )
    visible_contributor = Contributor.create!(
      login: "visible-user",
      email: "visible@example.com"
    )

    assert_not_includes Contributor.visible, hidden_contributor
    assert_not_includes Contributor.visible, hidden_profile_contributor
    assert_includes Contributor.visible, visible_contributor
  end

  test "hidden owner contributor does not fetch or import" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "hidden-user", hidden: true)
    contributor = Contributor.create!(
      login: "HIDDEN-USER",
      email: "hidden@example.com"
    )

    assert_nil contributor.fetch_profile
    assert_nil contributor.import_repos
    assert_not_requested :get, contributor.repos_api_url
  end
end
