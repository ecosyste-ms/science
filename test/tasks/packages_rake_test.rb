require "test_helper"
require "rake"

class PackagesRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LIMIT MAX_SCORE PURLS RETRY_ERRORS RETRY_STOPPED].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:sync_registries")
    Rake::Task["packages:sync_registries"].reenable
    Rake::Task["packages:resolve_dependencies"].reenable
    Rake::Task["packages:sync_metadata"].reenable
    Rake::Task["packages:match_projects"].reenable
    Rake::Task["packages:normalize_rankings"].reenable
    Rake::Task["packages:science_score_review"].reenable
    SyncProjectWorker.jobs.clear
    @original_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    @original_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    SyncProjectWorker.jobs.clear
  end

  test "syncs registries through the rake entrypoint" do
    request = stub_request(
      :get,
      "https://packages.ecosyste.ms/api/v1/registries?per_page=1000"
    ).to_return(
      status: 200,
      headers: { "total-count" => "2" },
      body: [
        {
          name: "rubygems.org",
          url: "https://rubygems.org/",
          ecosystem: "rubygems",
          purl_type: "gem",
          default: true,
          metadata: { rate_limit: 10 },
          updated_at: "2026-08-30T12:00:00Z",
        },
        {
          name: "gem.coop",
          url: "https://gem.coop",
          ecosystem: "rubygems",
          purl_type: "gem",
          default: false,
          metadata: {},
          updated_at: "2026-08-30T12:00:00Z",
        },
      ].to_json
    )

    output, = capture_io { Rake::Task["packages:sync_registries"].invoke }
    Rake::Task["packages:sync_registries"].reenable
    second_output, = capture_io { Rake::Task["packages:sync_registries"].invoke }

    assert_requested request, times: 2
    assert_equal 2, PackageRegistry.count
    assert_equal "gem.coop", PackageRegistry.find_by!(default: false).name
    assert_equal "https://rubygems.org", PackageRegistry.find_by!(default: true).url
    assert_includes output, "registries: 2"
    assert_includes output, "created: 2"
    assert_includes second_output, "created: 0"
    assert_includes second_output, "updated: 0"
  end

  test "prints a bounded Science Score review through the rake entrypoint" do
    registry = PackageRegistry.create!(
      name: "cran.r-project.org",
      url: "https://cran.r-project.org",
      ecosystem: "cran",
      purl_type: "cran",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "testthat",
      purl: "pkg:cran/testthat"
    )
    ENV["PURLS"] = package.purl

    output, = capture_io do
      Rake::Task["packages:science_score_review"].invoke
    end
    payload = JSON.parse(output)

    assert_equal package.purl, payload.dig("packages", 0, "purl")
    assert_equal "publishing_project_not_linked",
      payload.dig("packages", 0, "status")
  end

  test "resolves a bounded dependency batch through the rake entrypoint" do
    PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
    project = Project.create!(url: "https://github.com/example/package-rake")
    dependency = ProjectDependency.create!(
      project: project,
      ecosystem: "rubygems",
      package_name: "rails",
      purl: "pkg:gem/rails",
      direct: true
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["packages:resolve_dependencies"].invoke }

    assert_equal "rails", dependency.reload.package.name
    assert_includes output, "selected: 1"
    assert_includes output, "resolved: 1"
    assert_includes output, "dependency_rows: 1"
  end

  test "syncs package metadata through the rake entrypoint" do
    registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
    low_usage_package = Package.create!(
      package_registry: registry,
      name: "low-usage",
      purl: "pkg:gem/low-usage"
    )
    package = Package.create!(
      package_registry: registry,
      name: "rails",
      purl: "pkg:gem/rails"
    )
    2.times do |index|
      project = Project.create!(
        url: "https://github.com/example/package-metadata-priority-#{index}"
      )
      ProjectDependency.create!(
        project: project,
        package: package,
        ecosystem: "rubygems",
        package_name: package.name,
        purl: package.purl,
        direct: true
      )
    end
    request = stub_request(
      :get,
      "https://packages.ecosyste.ms/api/v1/packages/lookup"
    ).with(query: { "purl" => "pkg:gem/rails" }).to_return(
      status: 200,
      body: [{
        id: 123,
        name: "rails",
        namespace: nil,
        purl: "pkg:gem/rails",
        repository_url: "https://github.com/rails/rails",
        updated_at: "2026-08-30T12:00:00Z",
        registry: { name: "rubygems.org" },
      }].to_json
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["packages:sync_metadata"].invoke }

    assert_requested request
    assert_equal 123, package.reload.ecosystems_id
    assert_nil low_usage_package.reload.ecosystems_checked_at
    assert_includes output, "selected: 1"
    assert_includes output, "matched: 1"
  end

  test "matches package projects through the rake entrypoint" do
    registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
    project = Project.create!(url: "https://github.com/numpy/numpy")
    package = Package.create!(
      package_registry: registry,
      name: "numpy",
      purl: "pkg:pypi/numpy",
      repository_url: "git@github.com:NumPy/numpy.git"
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["packages:match_projects"].invoke }

    assert_equal project, package.reload.published_by_project
    assert_includes output, "selected: 1"
    assert_includes output, "matched: 1"
  end

  test "discovers package projects through the rake entrypoint" do
    registry = PackageRegistry.create!(
      name: "pypi.org",
      url: "https://pypi.org",
      ecosystem: "pypi",
      purl_type: "pypi",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "unmatched",
      purl: "pkg:pypi/unmatched",
      repository_url: "https://github.com/numpy/unmatched"
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["packages:match_projects"].invoke }

    project = Project.find_by!(url: "https://github.com/numpy/unmatched")
    assert_equal project, package.reload.published_by_project
    assert_equal [[project.id]], SyncProjectWorker.jobs.map { |job| job["args"] }
    assert_includes output, "discovered: 1"
  end

  test "normalizes package rankings through the rake entrypoint" do
    registry = PackageRegistry.create!(
      name: "rubygems.org",
      url: "https://rubygems.org",
      ecosystem: "rubygems",
      purl_type: "gem",
      default: true
    )
    package = Package.create!(
      package_registry: registry,
      name: "rails",
      purl: "pkg:gem/rails",
      metadata: {
        "dependent_repos_count" => 500,
        "rankings" => { "average" => 1.5 },
      }
    )
    package.update_columns(ranking_metadata_normalized_at: nil)
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["packages:normalize_rankings"].invoke }

    assert_not_nil package.reload.ranking_metadata_normalized_at
    assert_equal 500, package.general_dependent_repositories_count
    assert_in_delta 1.5, package.average_top_percentage
    assert_includes output, "selected: 1"
    assert_includes output, "normalized: 1"
  end
end
