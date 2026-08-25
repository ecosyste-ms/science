require "test_helper"

class OwnerTest < ActiveSupport::TestCase
  def setup
    %w[edu nasa.gov].each do |domain|
      create_research_organization_domain(domain, version: "owner")
    end
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  def teardown
    ResearchOrganizationDomainMatcher.reset_cache!
  end

  test "valid owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.new(host: host, login: "testuser")
    assert owner.valid?
  end

  test "visible scope excludes hidden owners" do
    host = Host.create!(name: "GitHub")
    visible_owner = Owner.create!(host: host, login: "visible", hidden: false)
    hidden_owner = Owner.create!(host: host, login: "hidden", hidden: true)

    assert_includes Owner.visible, visible_owner
    assert_not_includes Owner.visible, hidden_owner
  end

  test "hidden scope only includes hidden owners" do
    host = Host.create!(name: "GitHub")
    visible_owner = Owner.create!(host: host, login: "visible", hidden: false)
    hidden_owner = Owner.create!(host: host, login: "hidden", hidden: true)

    assert_includes Owner.hidden, hidden_owner
    assert_not_includes Owner.hidden, visible_owner
  end

  test "requires login" do
    host = Host.create!(name: "GitHub")
    owner = Owner.new(host: host)
    assert_not owner.valid?
    assert_includes owner.errors[:login], "can't be blank"
  end

  test "validates uniqueness of login scoped to host (case insensitive)" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "testuser")
    owner = Owner.new(host: host, login: "TestUser")
    assert_not owner.valid?
    assert_includes owner.errors[:login], "has already been taken"
  end

  test "allows same login on different hosts" do
    github = Host.create!(name: "GitHub")
    gitlab = Host.create!(name: "GitLab")

    owner1 = Owner.create!(host: github, login: "testuser")
    owner2 = Owner.new(host: gitlab, login: "testuser")

    assert owner2.valid?
  end

  test "validates uniqueness of uuid scoped to host" do
    host = Host.create!(name: "GitHub")
    Owner.create!(host: host, login: "user1", uuid: "123")
    owner = Owner.new(host: host, login: "user2", uuid: "123")
    assert_not owner.valid?
    assert_includes owner.errors[:uuid], "has already been taken"
  end

  test "allows nil uuid" do
    host = Host.create!(name: "GitHub")
    owner1 = Owner.create!(host: host, login: "user1", uuid: nil)
    owner2 = Owner.create!(host: host, login: "user2", uuid: nil)
    assert owner1.valid?
    assert owner2.valid?
  end

  test "belongs to host" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    assert_equal host, owner.host
  end

  test "has many projects" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "testuser")
    project1 = Project.create!(url: "https://github.com/test/repo1", owner_record: owner)
    project2 = Project.create!(url: "https://github.com/test/repo2", owner_record: owner)

    assert_equal 2, owner.projects.count
    assert_includes owner.projects, project1
    assert_includes owner.projects, project2
  end

  test "institutional? returns true for org with edu domain" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "stanford", kind: "organization", website: "stanford.edu")

    assert owner.institutional?
    assert_equal "edu", owner.institutional_domain
    assert_equal "stanford.edu", owner.website_domain
  end

  test "institutional? returns true for org with gov domain" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "nasa", kind: "organization", website: "https://nasa.gov")

    assert owner.institutional?
  end

  test "institutional? returns false for org with non-institutional domain" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "mycompany", kind: "organization", website: "mycompany.com")

    assert_not owner.institutional?
  end

  test "institutional? returns false for user owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "johndoe", kind: "user", website: "johndoe.edu")

    assert_not owner.institutional?
  end

  test "institutional? returns false when no website" do
    host = Host.create!(name: "GitHub")
    owner = Owner.create!(host: host, login: "someorg", kind: "organization", website: nil)

    assert_not owner.institutional?
  end

  test "organizations scope returns only organizations" do
    host = Host.create!(name: "GitHub")
    org = Owner.create!(host: host, login: "org1", kind: "organization")
    user = Owner.create!(host: host, login: "user1", kind: "user")

    assert_includes Owner.organizations, org
    assert_not_includes Owner.organizations, user
  end

  test "institutional scope uses the stored classification" do
    host = Host.create!(name: "GitHub")
    institution = Owner.create!(host: host, login: "institution", kind: "organization", website: "nasa.gov")
    company = Owner.create!(host: host, login: "company", kind: "organization", website: "example.com")

    assert_includes Owner.institutional, institution
    assert_not_includes Owner.institutional, company
  end
end
