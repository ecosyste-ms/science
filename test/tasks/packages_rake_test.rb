require "test_helper"
require "rake"

class PackagesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("packages:sync_registries")
    Rake::Task["packages:sync_registries"].reenable
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
end
