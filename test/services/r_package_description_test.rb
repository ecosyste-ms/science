require "test_helper"

class RPackageDescriptionTest < ActiveSupport::TestCase
  test "keeps selected folded fields and omits empty or duplicate values" do
    fields = RPackageDescription.fields("Package: example\nDescription: First line\n  continued.\nAuthors@R: c(\n  stop('no'))\nTitle:\nURL: https://example.org\nURL: https://other.example.org\n")
    assert_equal({ "Package" => "example", "Description" => "First line continued." }, fields)
    assert_empty RPackageDescription.fields("malformed\n  orphan continuation\n")
    assert_empty RPackageDescription.urls("not a URL https://[invalid")
  end

  test "resource collection rejects unsafe DESCRIPTION paths and retains evidence on failed reads" do
    project = Project.create!(url: "https://github.com/r/example", repository: {}, brief: {
      "resources" => {}, "manifests" => [{ "path" => "DESCRIPTION" }, { "path" => "../DESCRIPTION" }, { "path" => "/DESCRIPTION" }],
    })
    assert_equal ["DESCRIPTION"], RepositoryResources.paths(project.brief)
    file = { "path" => "DESCRIPTION", "status" => "ok", "content" => "Package: example\nDescription: Kept text\n", "sha256" => "digest", "retrieved_at" => Time.current.iso8601 }
    RepositoryResources.store(project, [file], revision: "first")
    previous = project.reload.repository.dig("metadata", "r_package_descriptions")
    RepositoryResources.store(project, [{ "path" => "DESCRIPTION", "status" => "error" }], revision: "second")
    assert_equal previous, project.reload.repository.dig("metadata", "r_package_descriptions")
    project.update!(brief: project.brief.merge("manifests" => []))
    RepositoryResources.store(project, [], revision: "third")
    assert_empty project.reload.repository.dig("metadata", "r_package_descriptions")
  end

  test "keeps multiple detected manifests and incomplete fields separate in context" do
    project = Project.create!(url: "https://github.com/r/multiple", repository: {}, brief: {
      "resources" => {}, "manifests" => [{ "path" => "one/DESCRIPTION" }, { "path" => "two/DESCRIPTION" }],
    })
    files = [
      { "path" => "one/DESCRIPTION", "status" => "ok", "content" => "Package: one\nDescription: First package\n" },
      { "path" => "two/DESCRIPTION", "status" => "ok", "content" => "Title: Second package\nBugReports: malformed\n" },
    ]
    RepositoryResources.store(project, files, revision: "revision")
    manifests = ProjectSearchContext.new(project.reload).as_json.fetch(:package_manifests)
    assert_equal %w[one/DESCRIPTION two/DESCRIPTION], manifests.pluck("path")
    assert_equal "one", manifests.first.fetch("names").sole.fetch(:value)
    assert_empty manifests.last.fetch("names")
    assert_equal "Second package", manifests.last.fetch("titles").sole.fetch(:value)
    assert_empty manifests.last.fetch("bug_reports")
  end
end
