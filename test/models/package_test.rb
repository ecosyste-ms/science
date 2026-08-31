require "test_helper"

class PackageTest < ActiveSupport::TestCase
  setup do
    @registry = PackageRegistry.create!(
      name: "npmjs.org",
      url: "https://registry.npmjs.org",
      ecosystem: "npm",
      purl_type: "npm",
      default: true
    )
  end

  test "stores a canonical package-level purl" do
    package = Package.create!(
      package_registry: @registry,
      name: "@Fudge-AI/Browser",
      purl: "pkg:NPM/%40Fudge-AI/Browser@1.0.0#lib/index.js"
    )

    assert_equal "pkg:npm/%40Fudge-AI/Browser", package.purl
  end

  test "keeps packages with the same name separate by registry" do
    other_registry = PackageRegistry.create!(
      name: "npm.example.com",
      url: "https://npm.example.com",
      ecosystem: "npm",
      purl_type: "npm"
    )

    Package.create!(package_registry: @registry, name: "example")
    other = Package.create!(package_registry: other_registry, name: "example")

    assert_predicate other, :persisted?
  end

  test "preserves qualifiers used to distinguish a non-default registry" do
    package = Package.create!(
      package_registry: @registry,
      name: "example",
      purl: "pkg:npm/example@1.0.0?repository_url=https://npm.example.com"
    )

    assert_equal(
      "pkg:npm/example?repository_url=https://npm.example.com",
      package.purl
    )
  end

  test "checks uniqueness after purl canonicalization" do
    Package.create!(
      package_registry: @registry,
      name: "example",
      purl: "pkg:npm/example"
    )
    duplicate = Package.new(
      package_registry: @registry,
      name: "other-name",
      purl: "pkg:npm/example@1.0.0"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:purl], "has already been taken"
  end

  test "requires the purl type to match the registry" do
    package = Package.new(
      package_registry: @registry,
      name: "example",
      purl: "pkg:gem/example"
    )

    assert_not package.valid?
    assert_includes package.errors[:purl], "type must match the package registry"
  end

  test "rejects an invalid purl" do
    package = Package.new(
      package_registry: @registry,
      name: "example",
      purl: "https://registry.npmjs.org/example"
    )

    assert_not package.valid?
    assert package.errors[:purl].any?
  end

  test "normalizes package ranking metadata on write" do
    package = Package.create!(
      package_registry: @registry,
      name: "ranked",
      purl: "pkg:npm/ranked",
      metadata: {
        "dependent_repos_count" => 120,
        "rankings" => {
          "dependent_repos_count" => 2.5,
          "average" => 3.5,
        },
      }
    )

    assert_equal 120, package.general_dependent_repositories_count
    assert_in_delta 2.5, package.dependent_repositories_top_percentage
    assert_in_delta 3.5, package.average_top_percentage
    assert_not_nil package.ranking_metadata_normalized_at
  end

  test "ranks packages by distinct scientific dependent projects" do
    popular = Package.create!(
      package_registry: @registry,
      name: "popular",
      purl: "pkg:npm/popular",
      metadata: {
        "dependent_repos_count" => 200,
        "rankings" => {
          "dependent_repos_count" => 0.0,
          "average" => 100.0,
        },
      }
    )
    other = Package.create!(
      package_registry: @registry,
      name: "other",
      purl: "pkg:npm/other",
      metadata: {
        "dependent_repos_count" => 20,
        "rankings" => { "average" => 10.0 },
      }
    )
    2.times do |index|
      project = Project.create!(
        url: "https://github.com/test/package-ranking-#{index}",
        science_score: 70
      )
      ProjectDependency.create!(
        project: project,
        package: popular,
        ecosystem: "npm",
        package_name: popular.name,
        purl: popular.purl,
        direct: true
      )
      next unless index.zero?

      ProjectDependency.create!(
        project: project,
        package: other,
        ecosystem: "npm",
        package_name: other.name,
        purl: other.purl,
        direct: true
      )
      other.update!(published_by_project: project)
    end

    ranked = Package.ranked_by_scientific_dependents
    counts = ranked.map do |package|
      package.scientific_dependents_count.to_i
    end

    assert_equal 2, ranked.count(:all)
    assert_equal [popular, other], ranked.to_a
    assert_equal [2, 1], counts
    assert_equal 200, ranked.first.general_dependent_repositories_count.to_i
    assert_in_delta 0.0,
      ranked.first.dependent_repositories_top_percentage.to_f
    assert_in_delta 0.0,
      ranked.first.science_relevance_top_percentage.to_f
    assert_nil ranked.second.dependent_repositories_top_percentage
    assert_in_delta 10.0, ranked.second.average_top_percentage.to_f
    assert_in_delta 1.0, ranked.first.science_usage_percentage.to_f
    assert_in_delta 5.0, ranked.second.science_usage_percentage.to_f

    relevant = Package.ranked_by_scientific_dependents(
      sort: "science_relevance"
    ).to_a

    assert_equal [other, popular], relevant
    assert_in_delta 70.0, relevant.first.repository_science_score.to_f
    assert_in_delta 0.7, relevant.first.science_relevance_score.to_f
    assert_nil relevant.second.science_relevance_score
  end
end
