require "test_helper"
require "codemeta_research"

class CodemetaResearchTest < ActiveSupport::TestCase
  # ---- normalize_version ----

  test "normalize_version strips v prefix, version prefix, whitespace and downcases" do
    assert_equal "1.2.3", CodemetaResearch.normalize_version("v1.2.3")
    assert_equal "1.2.3", CodemetaResearch.normalize_version("V1.2.3")
    assert_equal "1.2.3", CodemetaResearch.normalize_version("  1.2.3  ")
    assert_equal "1.2.3", CodemetaResearch.normalize_version("Version 1.2.3")
    assert_equal "1.2.3", CodemetaResearch.normalize_version("version-1.2.3")
    assert_equal "1.2.3", CodemetaResearch.normalize_version("version_1.2.3")
    assert_nil CodemetaResearch.normalize_version(nil)
    assert_nil CodemetaResearch.normalize_version("")
    assert_nil CodemetaResearch.normalize_version("   ")
  end

  # ---- clone_and_analyze ----

  test "clone_and_analyze returns empty array when project has no repository" do
    project = Project.new(url: "https://github.com/x/y")
    assert_equal [], CodemetaResearch.clone_and_analyze(project)
  end

  test "clone_and_analyze returns error when clone fails" do
    Dir.mktmpdir do |base|
      project = Project.new(url: "https://github.com/x/y", repository: { "clone_url" => "/nonexistent/path" })
      results = nil
      capture_subprocess_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }
      assert_equal 1, results.length
      assert_equal "Failed to clone repository", results.first[:error]
      assert_nil results.first[:release_tag]
    end
  end

  test "clone_and_analyze reports codemeta version and tag match for each tag" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: "v1.0.0", codemeta_version: "1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      assert_equal 1, results.length
      r = results.first
      assert_equal project.id, r[:project_id]
      assert_equal "v1.0.0", r[:release_tag]
      assert r[:codemeta_exists]
      assert_equal "codemeta.json", r[:codemeta_file_path]
      assert_equal "1.0.0", r[:codemeta_version]
      assert r[:version_matches_tag]
      assert_nil r[:error]
    end
  end

  test "clone_and_analyze reports version mismatch" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: "v2.0.0", codemeta_version: "1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      assert_equal false, results.first[:version_matches_tag]
    end
  end

  test "clone_and_analyze returns error when repo has no tags" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: nil, codemeta_version: "1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      assert_equal "No tags found in repository", results.first[:error]
    end
  end

  test "clone_and_analyze does not pass tag names through a shell" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      marker = File.join(work, "marker")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: "v1.0.0", codemeta_version: "1.0.0")
      hostile = "v2;touch${IFS}#{marker}"
      assert system("git", "-C", upstream, "tag", hostile)

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      refute File.exist?(marker)
      result = results.find { |r| r[:release_tag] == hostile }
      assert_equal "1.0.0", result[:codemeta_version]
      assert_nil result[:error]
    end
  end

  test "clone_and_analyze reads tags that look like options" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: "v1.0.0", codemeta_version: "1.0.0")
      assert system("git", "-C", upstream, "update-ref", "refs/tags/--orphan", "HEAD")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      result = results.find { |r| r[:release_tag] == "--orphan" }
      assert_equal "1.0.0", result[:codemeta_version]
      assert_nil result[:error]
    end
  end

  test "clone_and_analyze reads a tag when a tracked file has the same path as its ref" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: nil, codemeta_version: "1.0.0")
      FileUtils.mkdir_p(File.join(upstream, "refs", "tags"))
      File.write(File.join(upstream, "refs", "tags", "v1.0.0"), "x")
      assert system("git", "-C", upstream, "add", "refs")
      assert system("git", "-C", upstream, "commit", "--quiet", "-m", "file named like a ref")
      assert system("git", "-C", upstream, "tag", "v1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      assert_nil results.first[:error]
      assert_equal "1.0.0", results.first[:codemeta_version]
    end
  end

  test "clone_and_analyze does not follow a symlinked codemeta file" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      outside = File.join(work, "outside.json")
      FileUtils.mkdir_p(base)
      File.write(outside, JSON.generate(version: "9.9.9"))
      build_repo(upstream, tag: nil, codemeta_version: nil)
      File.symlink(outside, File.join(upstream, "codemeta.json"))
      assert system("git", "-C", upstream, "add", "codemeta.json")
      assert system("git", "-C", upstream, "commit", "--quiet", "-m", "link")
      assert system("git", "-C", upstream, "tag", "v1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

      assert_nil results.first[:codemeta_version]
      assert_match(/JSON parse error/, results.first[:error])
    end
  end

  test "clone_and_analyze does not run commands from the clone url" do
    Dir.mktmpdir do |work|
      marker = File.join(work, "marker")
      ["x;touch #{marker}", "ext::sh -c touch% #{marker}"].each_with_index do |clone_url, index|
        base = File.join(work, "clones-#{index}")
        FileUtils.mkdir_p(base)
        project = Project.new(url: "https://github.com/x/y", repository: { "clone_url" => clone_url })
        results = nil
        capture_subprocess_io { results = CodemetaResearch.clone_and_analyze(project, base_dir: base) }

        assert_equal "Failed to clone repository", results.first[:error]
        refute File.exist?(marker)
      end
    end
  end

  # ---- analyze_history ----

  test "analyze_history returns empty array when project has no repository" do
    project = Project.new(url: "https://github.com/x/y")
    assert_equal [], CodemetaResearch.analyze_history(project)
  end

  test "analyze_history returns error when clone fails" do
    Dir.mktmpdir do |base|
      project = Project.new(url: "https://github.com/x/y", repository: { "clone_url" => "/nonexistent/path" })
      results = nil
      capture_subprocess_io { results = CodemetaResearch.analyze_history(project, base_dir: base) }
      assert_equal "Failed to clone repository", results.first[:error]
    end
  end

  test "analyze_history extracts commit info and codemeta version per commit" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: "v1.0.0", codemeta_version: "1.0.0")

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.analyze_history(project, base_dir: base) }

      assert_equal 1, results.length
      r = results.first
      assert_equal project.id, r[:project_id]
      assert_equal "codemeta.json", r[:file_path]
      assert_equal "1.0.0", r[:codemeta_version]
      assert_equal "add codemeta", r[:commit_message]
      assert_match(/\A[0-9a-f]{40}\z/, r[:commit_hash])
      assert_nil r[:parse_error]
    end
  end

  test "analyze_history returns error when no codemeta file in history" do
    Dir.mktmpdir do |work|
      upstream = File.join(work, "upstream")
      base = File.join(work, "clones")
      FileUtils.mkdir_p(base)
      build_repo(upstream, tag: nil, codemeta_version: nil)

      project = Project.create!(url: "https://github.com/x/y", repository: { "clone_url" => upstream })
      results = nil
      capture_io { results = CodemetaResearch.analyze_history(project, base_dir: base) }

      assert_equal "No codemeta file found in repository history", results.first[:error]
    end
  end

  def build_repo(path, tag:, codemeta_version:)
    FileUtils.mkdir_p(path)
    Dir.chdir(path) do
      system("git init --quiet --initial-branch=main")
      system("git config user.email test@example.com")
      system("git config user.name test")
      system("git config commit.gpgsign false")
      system("git config tag.gpgsign false")
      File.write("README.md", "hi")
      system("git add README.md && git commit --quiet -m init")
      if codemeta_version
        File.write("codemeta.json", JSON.generate(version: codemeta_version))
        system("git add codemeta.json && git commit --quiet -m 'add codemeta'")
      end
      system("git tag #{tag}") if tag
    end
  end
end
