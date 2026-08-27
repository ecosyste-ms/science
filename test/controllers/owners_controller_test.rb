require "test_helper"

class OwnersControllerTest < ActionDispatch::IntegrationTest
  def setup
    create_research_organization_domain("edu", version: "owners-controller")
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  def teardown
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "should get index" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")

    get host_owners_url(host.name)
    assert_response :success
    assert_select "h1", /#{host.name}/
  end

  test "should show owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser", name: "Test User")
    project = Project.create!(url: "https://github.com/testuser/repo", owner_record: owner, science_score: 5.0)

    get host_owner_url(host.name, owner.login)
    assert_response :success
    assert_select "h1", /#{host.name}/
    assert_select "h1", /#{owner.login}/
  end

  test "should find owner case insensitively" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    project = Project.create!(url: "https://github.com/testuser/repo", owner_record: owner, science_score: 5.0)

    get host_owner_url(host.name, "TestUser")
    assert_response :success
  end

  test "should return 404 for missing owner" do
    host = Host.create!(name: "GitHub")

    get host_owner_url(host.name, "nonexistent")
    assert_response :not_found
  end

  test "should only show scientific projects" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    Project.create!(
      url: "https://github.com/testuser/below-threshold",
      name: "below-threshold",
      owner_record: owner,
      science_score: 19.9
    )
    scientific = Project.create!(
      url: "https://github.com/testuser/scientific",
      name: "scientific-project",
      owner_record: owner,
      science_score: 20
    )

    get host_owner_url(host.name, owner.login)

    assert_response :success
    assert_equal [scientific], assigns(:projects)
    assert_match "scientific-project", response.body
    assert_no_match "below-threshold", response.body
  end

  test "research organizations action shows classified organizations" do
    create_research_organization_domain("research.example", source: "ror", version: "owners-controller")
    ResearchOrganizationDomainMatcher.reset_cache!

    host = Host.create!(name: "GitHub")
    institutional_owner = Owner.create!(host: host, login: "stanford", kind: "organization", website: "stanford.edu")
    ror_owner = Owner.create!(host: host, login: "ror-owner", kind: "organization", website: "research.example")
    regular_owner = Owner.create!(host: host, login: "mycompany", kind: "organization", website: "mycompany.com")
    user_owner = Owner.create!(host: host, login: "johndoe", kind: "user", website: "johndoe.com")

    get research_organizations_url
    assert_response :success
    assert_select "h1", /Research Organizations/
    assert_match institutional_owner.login, response.body
    assert_match ror_owner.login, response.body
    assert_no_match regular_owner.login, response.body
    assert_no_match user_owner.login, response.body
  end

  test "institutional owners redirects to research organizations" do
    get institutional_owners_url
    assert_redirected_to research_organizations_url
  end

  test "hidden owners are excluded from the index" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "visible-owner")
    Owner.create!(host: host, login: "hidden-owner", hidden: true)

    get host_owners_url(host.name)

    assert_response :success
    assert_match "visible-owner", response.body
    assert_no_match "hidden-owner", response.body
  end

  test "show falls back to science_score for unknown sort column" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    Project.create!(url: "https://github.com/testuser/repo", owner_record: owner, science_score: 5.0)

    get host_owner_url(host.name, owner.login), params: { sort: 'pg_sleep(1)', order: 'nope' }
    assert_response :success
    sql = assigns(:scope).to_sql
    assert_match 'ORDER BY science_score DESC NULLS LAST', sql
    assert_no_match 'pg_sleep', sql
  end

  test "hidden owner returns 404" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "HIDDEN-OWNER", hidden: true)

    get host_owner_url(host.name, "hidden-owner")

    assert_response :not_found
  end
end
