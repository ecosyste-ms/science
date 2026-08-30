require "test_helper"
require "rake"

class PackagesRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LIMIT RETRY_ERRORS RETRY_STOPPED].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:sync_registries")
    Rake::Task["packages:sync_registries"].reenable
    Rake::Task["packages:resolve_dependencies"].reenable
    Rake::Task["packages:sync_metadata"].reenable
    Rake::Task["packages:match_projects"].reenable
    @original_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    @original_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
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
end
