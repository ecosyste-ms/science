require "test_helper"
require "rake"
require "tmpdir"
require "fileutils"
require "open3"

class RJournalReviewRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("rjournal:review")
    @directory = Dir.mktmpdir("rjournal-review")
    @output = File.join(@directory, "report.json")
    @repo = File.join(@directory, "publisher")
    FileUtils.mkdir_p(@repo)
    git("init", "-q")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.org")
    @content = Rails.root.join("test/fixtures/files/rjournal_hdtg.Rmd").read
    add_article("RJ-2026-038", @content)
    git("add", ".")
    git("commit", "-qm", "Published article")
    @revision = git("rev-parse", "HEAD").strip
    git("update-ref", "refs/remotes/origin/published", @revision)
  end

  teardown { FileUtils.remove_entry(@directory) }

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @repo, *arguments)
    assert status.success?, error
    output
  end

  def add_article(slug, content)
    directory = File.join(@repo, "_articles", slug)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{slug}.Rmd"), content)
  end

  def publish
    git("add", ".")
    git("commit", "-qm", "More published articles")
    git("update-ref", "refs/remotes/origin/published", "HEAD")
  end

  def review(**env)
    options = { "REPOSITORY" => @repo, "OUTPUT" => @output, "LIMIT" => "20", "SLUGS" => nil, "AFTER" => nil }.merge(env.transform_keys(&:to_s))
    before = ENV.to_h.slice(*options.keys)
    options.each { |key, value| ENV[key] = value }
    Rake::Task["rjournal:review"].reenable
    counts = [Paper.count, Project.count, Package.count]
    capture_io { Rake::Task["rjournal:review"].invoke }
    assert_equal counts, [Paper.count, Project.count, Package.count]
    JSON.parse(File.read(@output))
  ensure
    options.each_key { |key| ENV[key] = before[key] }
  end

  test "hdtg is the subject while ggplot2 Rcpp and other listed packages remain mentions" do
    report = review
    assert_equal @revision, report["revision"]
    row = report["records"].sole
    assert_equal [{ "ecosystem" => "cran", "name" => "hdtg" }], row["subject_packages"]
    assert_equal 8, row["mentioned_packages"].size
    assert_includes row["mentioned_packages"].pluck("name"), "ggplot2"
    assert_includes row["mentioned_packages"].pluck("name"), "Rcpp"
    assert_equal "candidate", row["status"]
  end

  test "working tree and other branch edits cannot replace published evidence" do
    add_article("RJ-2026-038", @content.sub("hdtg:", "ggplot2:"))
    git("add", ".")
    git("commit", "-qm", "Unpublished changes")
    report = review
    assert_equal @revision, report["revision"]
    assert_equal ["hdtg"], report["records"].sole["subject_packages"].pluck("name")
  end

  test "ambiguous titles drafts malformed package entries and future dates remain unresolved" do
    add_article("RJ-2026-039", @content.sub("RJ-2026-038", "RJ-2026-039").sub("hdtg:", "Comparing hdtg and ggplot2:"))
    add_article("RJ-2026-040", @content.sub("RJ-2026-038", "RJ-2026-040").sub("draft: false", "draft: true"))
    add_article("RJ-2026-041", @content.sub("RJ-2026-038", "RJ-2026-041").sub("- hdtg", "- hdtg 1.0"))
    add_article("RJ-2026-042", @content.sub("RJ-2026-038", "RJ-2026-042").sub("2026-07-26", "2099-07-26"))
    publish
    rows = review["records"].index_by { |row| row["slug"] }
    %w[RJ-2026-039 RJ-2026-040 RJ-2026-041 RJ-2026-042].each { |slug| assert_equal "unresolved", rows[slug]["status"] }
    assert_equal "hdtg 1.0", rows["RJ-2026-041"]["invalid_package_entries"].sole["value"]
  end

  test "bounded descending pagination and explicit article selection retain publisher paths" do
    add_article("RJ-2026-039", @content.sub("RJ-2026-038", "RJ-2026-039"))
    publish
    first = review(LIMIT: "1")
    assert_equal "RJ-2026-039", first["next_after"]
    second = review(LIMIT: "1", AFTER: first["next_after"])
    assert_equal "RJ-2026-038", second["records"].sole["slug"]
    assert_nil second["next_after"]
    assert_equal "_articles/RJ-2026-038/RJ-2026-038.Rmd", review(SLUGS: "RJ-2026-038")["records"].sole["source_path"]
    assert_raises(ArgumentError) { review(SLUGS: "../../anything") }
    assert_raises(ArgumentError) { review(LIMIT: "101") }
  end
end
