require "test_helper"

class OwnerTest < ActiveSupport::TestCase
  test "valid owner" do
    host = Host.create!(name: "GitHub")
    owner = Owner.new(host: host, login: "testuser")
    assert owner.valid?
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
end
