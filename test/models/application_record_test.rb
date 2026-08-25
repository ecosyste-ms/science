require "test_helper"

class ApplicationRecordTest < ActiveSupport::TestCase
  test "strips null bytes from string columns on save" do
    p = Project.create!(url: "https://github.com/x/y", name: "hel" + 0.chr + "lo")
    assert_equal "hello", p.reload.name
  end

  test "strips null bytes from array columns on save" do
    p = Project.create!(url: "https://github.com/x/y", keywords: ["a" + 0.chr + "b", "c"])
    assert_equal ["ab", "c"], p.reload.keywords
  end

  test "strips null bytes from jsonb columns on save" do
    p = Project.create!(url: "https://github.com/x/y", repository: { "description" => "x" + 0.chr + "y", "nested" => { "k" => "a" + 0.chr } })
    assert_equal "xy", p.reload.repository["description"]
    assert_equal "a", p.repository["nested"]["k"]
  end

  test "leaves clean values unchanged" do
    p = Project.create!(url: "https://github.com/x/y", name: "clean", keywords: ["a"], repository: { "k" => "v" })
    assert_equal "clean", p.reload.name
    assert_equal ["a"], p.keywords
    assert_equal({ "k" => "v" }, p.repository)
  end

  test "applies to other models" do
    p = Project.create!(url: "https://github.com/x/y")
    i = p.issues.create!(number: 1, title: "bug" + 0.chr)
    assert_equal "bug", i.reload.title
  end
end
