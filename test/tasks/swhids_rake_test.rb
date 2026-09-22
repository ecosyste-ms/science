require "test_helper"
require "rake"
require_relative "../support/swhid_pipeline"

class SwhidsRakeTest < ActiveSupport::TestCase
  include SwhidPipeline
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:contributions")
    Rake::Task["swhids:contributions"].reenable
  end

  test "contributions counts distinct identifiers from completed worker requests" do
    revision = "swh:1:rev:#{'a' * 40}"
    directory = "swh:1:dir:#{'b' * 40}"
    known = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { revision => { known: false }, directory => { known: false } }.to_json)
      .then.to_return(body: { revision => { known: true }, directory => { known: true } }.to_json)
      .then.to_return(body: { revision => { known: false }, directory => { known: false } }.to_json)
      .then.to_return(body: { revision => { known: true }, directory => { known: true } }.to_json)

    2.times do |index|
      origin = "https://github.com/example/contribution-#{index}"
      project = Project.create!(url: origin, science_score: 42, repository: { "clone_url" => origin }, swhids: {
        "status" => "success", "origin" => origin,
        "revision" => { "status" => "success", "swhid" => revision },
        "directory" => { "status" => "success", "swhid" => directory }
      })
      stub_request(:post, SwhidArchiver::ENDPOINT).with(query: { "visit_type" => "git", "origin_url" => origin })
        .to_return do
          { status: 200, body: { id: index + 1, origin_url: origin, visit_type: "git", save_request_date: Time.current.iso8601,
            save_request_status: "accepted", save_task_status: "succeeded" }.to_json }
        end
      perform_fetch(project.id)
    end

    output, = capture_io { Rake::Task["swhids:contributions"].invoke }

    assert_equal "SWHIDs archived after our request: 2\nRevisions: 1\nDirectories: 1\n", output
    assert_requested known, times: 4
  end

  test "contributions reports zero without submitting requests" do
    output, = capture_io { Rake::Task["swhids:contributions"].invoke }

    assert_equal "SWHIDs archived after our request: 0\nRevisions: 0\nDirectories: 0\n", output
    assert_not_requested :post, SwhidArchiver::ENDPOINT
  end
end
