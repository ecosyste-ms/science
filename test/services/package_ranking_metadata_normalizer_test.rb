require "test_helper"

class PackageRankingMetadataNormalizerTest < ActiveSupport::TestCase
  setup do
    @registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
  end

  test "normalizes a bounded package batch" do
    first = create_unnormalized_package(
      "first",
      dependent_repos_count: 120,
      rankings: {
        "dependent_repos_count" => 2.5,
        "average" => 3.5,
      }
    )
    second = create_unnormalized_package(
      "second",
      dependent_repos_count: 80,
      rankings: { "average" => 4.5 }
    )

    result = PackageRankingMetadataNormalizer.normalize_batch!(limit: 1)

    assert_equal({ selected: 1, normalized: 1 }, result)
    assert_equal 120, first.reload.general_dependent_repositories_count
    assert_in_delta 2.5, first.dependent_repositories_top_percentage
    assert_in_delta 3.5, first.average_top_percentage
    assert_not_nil first.ranking_metadata_normalized_at
    assert_nil second.reload.ranking_metadata_normalized_at
  end

  test "does not select normalized packages again" do
    package = create_unnormalized_package(
      "normalized",
      dependent_repos_count: 10,
      rankings: {}
    )

    PackageRankingMetadataNormalizer.normalize_batch!
    result = PackageRankingMetadataNormalizer.normalize_batch!

    assert_not_nil package.reload.ranking_metadata_normalized_at
    assert_equal({ selected: 0, normalized: 0 }, result)
  end

  def create_unnormalized_package(name, dependent_repos_count:, rankings:)
    package = Package.create!(
      package_registry: @registry,
      name: name,
      purl: "pkg:gem/#{name}",
      metadata: {
        "dependent_repos_count" => dependent_repos_count,
        "rankings" => rankings,
      }
    )
    package.update_columns(
      general_dependent_repositories_count: nil,
      dependent_repositories_top_percentage: nil,
      average_top_percentage: nil,
      ranking_metadata_normalized_at: nil
    )
    package
  end
end
