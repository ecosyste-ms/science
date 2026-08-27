require "test_helper"
require "rake"

class OpenAlexRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("open_alex:sync")
    @previous_api_key = ENV["OPENALEX_API_KEY"]
    ENV["OPENALEX_API_KEY"] = "test-key"
  end

  teardown do
    ENV["OPENALEX_API_KEY"] = @previous_api_key
  end

  test "sync imports the taxonomy and JOSS DOI assignments through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/open-alex-rake",
      joss_metadata: { "doi" => "10.21105/joss.00001" }
    )
    topics = 4_000.times.map { |index| topic_data(index) }
    primary = topics.first

    stub_request(:get, "https://api.openalex.org/topics")
      .with(query: { "api_key" => "test-key", "cursor" => "*", "per_page" => "100" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "meta" => { "next_cursor" => nil }, "results" => topics }.to_json
      )
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.21105/joss.00001"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "results" => [{
            "id" => "https://openalex.org/W1",
            "doi" => "https://doi.org/10.21105/joss.00001",
            "primary_topic" => primary.slice("id").merge("score" => 0.96),
            "topics" => [primary.slice("id").merge("score" => 0.96)],
          }],
        }.to_json
      )

    output, = capture_io { Rake::Task["open_alex:sync"].execute }

    assert_equal 4_000, OpenAlexTopic.active.count
    assignment = project.project_open_alex_topics.reload.sole
    assert_equal primary.fetch("id"), assignment.open_alex_topic.openalex_id
    assert_equal 0.96, assignment.score
    assert_includes output, "OpenAlex taxonomy:"
    assert_includes output, "OpenAlex JOSS topics:"
  end

  def topic_data(index)
    {
      "id" => "https://openalex.org/T#{index}",
      "display_name" => "Topic #{index}",
      "description" => "A research topic",
      "keywords" => ["research"],
      "subfield" => { "id" => 1712, "display_name" => "Software" },
      "field" => { "id" => 17, "display_name" => "Computer Science" },
      "domain" => { "id" => 3, "display_name" => "Physical Sciences" },
      "updated_date" => "2026-08-01",
    }
  end
end
