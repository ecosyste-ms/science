require "test_helper"

class OpenAlexApiClientTest < ActiveSupport::TestCase
  test "requires an API key" do
    assert_raises(ArgumentError) { OpenAlexApiClient.new(api_key: nil) }
  end

  test "paginates topics with a cursor and authenticates each request" do
    first_url = "https://api.openalex.org/topics"
    stub_request(:get, first_url)
      .with(query: { "api_key" => "test-key", "cursor" => "*", "per_page" => "100" })
      .to_return(json_response(results: [{ "id" => "T1" }], next_cursor: "next"))
    stub_request(:get, first_url)
      .with(query: { "api_key" => "test-key", "cursor" => "next", "per_page" => "100" })
      .to_return(json_response(results: [{ "id" => "T2" }], next_cursor: nil))

    pages = OpenAlexApiClient.new(api_key: "test-key").each_topic_page.to_a

    assert_equal [[{ "id" => "T1" }], [{ "id" => "T2" }]], pages
  end

  test "fetches several works through one DOI filter" do
    stub = stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.1/one|10.2/two",
        "per_page" => "100"
      ))
      .to_return(json_response(results: [{ "id" => "W1" }], next_cursor: nil))

    works = OpenAlexApiClient.new(api_key: "test-key").works_by_dois(
      ["https://doi.org/10.1/ONE", "doi:10.2/two"]
    )

    assert_equal [{ "id" => "W1" }], works
    assert_requested stub, times: 1
  end

  def json_response(results:, next_cursor:)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "meta" => { "next_cursor" => next_cursor }, "results" => results }.to_json,
    }
  end
end
