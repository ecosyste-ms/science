require "test_helper"

class ProjectScoringTest < ActiveSupport::TestCase
  test "repository_score is log of stars plus open issues" do
    p = Project.new(url: "https://x", repository: { "stargazers_count" => 90, "open_issues_count" => 10 })
    assert_in_delta Math.log(100), p.repository_score
  end

  test "repository_score is 0 without repository" do
    assert_equal 0, Project.new(url: "https://x").repository_score
  end

  test "packages_score is log of summed package metrics" do
    p = Project.new(url: "https://x", packages: [
      { "downloads" => 50, "dependent_packages_count" => 10, "dependent_repos_count" => 20,
        "docker_downloads_count" => 5, "docker_dependents_count" => 5, "maintainers" => [{ "uuid" => "a" }] },
      { "downloads" => 9, "maintainers" => [{ "uuid" => "a" }, { "uuid" => "b" }] },
    ])
    assert_in_delta Math.log(50 + 9 + 10 + 20 + 5 + 5 + 2), p.packages_score
  end

  test "packages_score is 0 without packages" do
    assert_equal 0, Project.new(url: "https://x").packages_score
  end

  test "commits_score is log of total_committers" do
    p = Project.new(url: "https://x", commits: { "total_committers" => 5 })
    assert_in_delta Math.log(5), p.commits_score
  end

  test "commits_score is 0 without commits" do
    assert_equal 0, Project.new(url: "https://x").commits_score
  end

  test "dependencies_score and events_score are 0" do
    p = Project.new(url: "https://x", dependencies: [{}], events: {})
    assert_equal 0, p.dependencies_score
    assert_equal 0, p.events_score
  end

  test "score_parts returns the five component scores" do
    p = Project.new(url: "https://x")
    p.stubs(repository_score: 1.0, packages_score: 2.0, commits_score: 3.0, dependencies_score: 0, events_score: 0)
    assert_equal [1.0, 2.0, 3.0, 0, 0], p.score_parts
  end

  test "update_score persists the sum of score_parts" do
    p = Project.create!(url: "https://github.com/x/y")
    p.stubs(:score_parts).returns([1.0, 2.0, 3.0])
    p.update_score
    assert_equal 6.0, p.reload.score
  end

  test "science_score_breakdown reads stored attribute with indifferent access" do
    p = Project.new(url: "https://x", science_score_breakdown: { "score" => 42 })
    assert_equal 42, p.science_score_breakdown[:score]
  end

  test "joss_idf_score delegates to JossIdfAnalyzer" do
    p = Project.new(url: "https://x")
    JossIdfAnalyzer.expects(:score_project).with(p).returns(0.5)
    assert_equal 0.5, p.joss_idf_score
  end

  test "instance calculate_idf delegates to class method with self" do
    p = Project.new(url: "https://x")
    Project.expects(:calculate_idf).with([p]).returns([])
    p.calculate_idf
  end

  test "preprocessed_readme strips markup and urls, downcases and normalizes whitespace" do
    p = Project.new(
      url: "https://x",
      readme: "# Hello   World\n\nSee https://example.com/foo for more.",
      repository: { "metadata" => { "files" => { "readme" => "README.md" } } }
    )
    result = p.preprocessed_readme
    assert_match "hello world", result
    refute_match "https://", result
    refute_match "#", result
  end

  test "preprocessed_readme returns empty string without readme" do
    assert_equal "", Project.new(url: "https://x").preprocessed_readme
  end
end
