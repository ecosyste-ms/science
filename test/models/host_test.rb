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

  test "find_by_name finds host by exact name" do
    host = Host.create!(name: "GitHub")
    assert_equal host, Host.find_by_name("GitHub")
  end

  test "find_by_name finds host case-insensitively" do
    host = Host.create!(name: "GitHub")
    assert_equal host, Host.find_by_name("github")
    assert_equal host, Host.find_by_name("GITHUB")
  end

  test "find_by_name returns nil for blank name" do
    assert_nil Host.find_by_name("")
    assert_nil Host.find_by_name(nil)
  end

  test "find_by_name returns nil for non-existent name" do
    assert_nil Host.find_by_name("nonexistent")
  end

  test "find_by_name! finds host by name" do
    host = Host.create!(name: "GitHub")
    assert_equal host, Host.find_by_name!("GitHub")
  end

  test "find_by_name! raises RecordNotFound for non-existent name" do
    assert_raises(ActiveRecord::RecordNotFound) { Host.find_by_name!("nonexistent") }
  end

  test "find_by_name! raises RecordNotFound for blank name" do
    assert_raises(ActiveRecord::RecordNotFound) { Host.find_by_name!(nil) }
  end

  test "validates uniqueness case-insensitively" do
    Host.create!(name: "GitHub")
    host = Host.new(name: "github")
    assert_not host.valid?
    assert_includes host.errors[:name], "has already been taken"
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
