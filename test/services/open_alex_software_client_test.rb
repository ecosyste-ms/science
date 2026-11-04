require "test_helper"

class OpenAlexSoftwareClientTest < ActiveSupport::TestCase
  test "update windows use saved bounds and preserve opaque cursor characters" do
    cursor = OpenAlexSoftwareClient.initial_cursor(from: "2026-11-01", until_time: "2026-11-03")
    request = stub_request(:get, "https://api.openalex.org/works").with(query: {
      api_key: "test-key", filter: "type:software,from_updated_date:2026-11-01,to_updated_date:2026-11-03",
      sort: "ids.openalex:asc", per_page: "100", select: OpenAlexSoftwareClient::FIELDS, cursor: "*"
    }).to_return(body: { results: [{ id: "https://openalex.org/W100", type: "software" }], meta: { next_cursor: "opaque/+==" } }.to_json)
    client = OpenAlexSoftwareClient.new(client: OpenAlexApiClient.new(api_key: "test-key"))
    page = client.page(after: cursor)
    state = JSON.parse(page[:next_cursor])
    assert_equal "opaque/+==", state["token"]
    assert_equal "W100", state["last_id"]
    assert_equal "2026-11-03", state["until"]
    assert_requested request
  end

  test "creation windows reject malformed dates and mismatched saved selections" do
    assert_raises(ArgumentError) { OpenAlexSoftwareClient.initial_cursor(until_time: "2026-02-31") }
    assert_raises(ArgumentError) { OpenAlexSoftwareClient.initial_cursor(from: "2026-11-04", until_time: "2026-11-03") }
    state = JSON.parse(OpenAlexSoftwareClient.initial_cursor(until_time: "2026-11-03"))
    state["select"] = "id,type"
    client = OpenAlexSoftwareClient.new(client: OpenAlexApiClient.new(api_key: "test-key"))
    assert_raises(ArgumentError) { client.page(after: JSON.generate(state)) }
    assert_not_requested :any, /api.openalex.org/
  end

  test "a record before the preceding page boundary is rejected" do
    state = JSON.parse(OpenAlexSoftwareClient.initial_cursor(until_time: "2026-11-03"))
    state.merge!("token" => "cursor2", "last_id" => "W200")
    stub_request(:get, "https://api.openalex.org/works").with(query: hash_including("api_key" => "test-key")).to_return(body: {
      results: [{ id: "https://openalex.org/W199", type: "software" }], meta: { next_cursor: nil }
    }.to_json)
    client = OpenAlexSoftwareClient.new(client: OpenAlexApiClient.new(api_key: "test-key"))
    assert_raises(OpenAlexApiClient::RequestError) { client.page(after: JSON.generate(state)) }
  end

  test "plan errors remain distinguishable from transient rate limits" do
    stub_request(:get, "https://api.openalex.org/works").with(query: { api_key: "test-key" })
      .to_return(status: 429, body: { error: "Plan upgrade required" }.to_json)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    error = assert_raises(OpenAlexApiClient::RequestError) { OpenAlexApiClient.new(api_key: "test-key").get("works") }
    assert_includes error.message, "Plan upgrade required"
  end
end
