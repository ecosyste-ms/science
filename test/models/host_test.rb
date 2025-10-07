require "test_helper"

class HostTest < ActiveSupport::TestCase
  test "valid host" do
    host = Host.new(name: "GitHub")
    assert host.valid?
  end

  test "requires name" do
    host = Host.new
    assert_not host.valid?
    assert_includes host.errors[:name], "can't be blank"
  end

  test "validates uniqueness of name" do
    Host.create!(name: "GitHub")
    host = Host.new(name: "GitHub")
    assert_not host.valid?
    assert_includes host.errors[:name], "has already been taken"
  end

  test "has many owners" do
    host = Host.create!(name: "GitHub")
    owner1 = Owner.create!(host: host, login: "owner1")
    owner2 = Owner.create!(host: host, login: "owner2")

    assert_equal 2, host.owners.count
    assert_includes host.owners, owner1
    assert_includes host.owners, owner2
  end

  test "has many projects" do
    host = Host.create!(name: "GitHub")
    project1 = Project.create!(url: "https://github.com/test/repo1", host: host)
    project2 = Project.create!(url: "https://github.com/test/repo2", host: host)

    assert_equal 2, host.projects.count
    assert_includes host.projects, project1
    assert_includes host.projects, project2
  end
end
