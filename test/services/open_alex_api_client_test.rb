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
        "filter" => "doi:10.1000/one|10.2000/two",
        "per_page" => "100"
      ))
      .to_return(json_response(results: [{ "id" => "W1" }], next_cursor: nil))

    works = OpenAlexApiClient.new(api_key: "test-key").works_by_dois(
      ["https://doi.org/10.1000/ONE", "doi:10.2000/two"]
    )

    assert_equal [{ "id" => "W1" }], works
    assert_requested stub, times: 1
  end

  test "escapes commas inside DOI filter values" do
    response = mock
    response.stubs(:success?).returns(true)
    response.stubs(:body).returns(json_response(
      results: [{ "id" => "W1" }],
      next_cursor: nil
    ).fetch(:body))
    connection = mock
    connection.expects(:get).with(
      "works",
      {
        api_key: "test-key",
        filter: "doi:10.5675/hywa_2017%2C3_1",
        per_page: 100,
        select: "id,doi,display_name,type,primary_topic,topics",
      }
    ).returns(response)

    works = OpenAlexApiClient.new(api_key: "test-key", connection: connection).works_by_dois(
      ["10.5675/hywa_2017,3_1"]
    )

    assert_equal [{ "id" => "W1" }], works
  end

  test "splits DOI filters at the OpenAlex limit" do
    dois = 101.times.map { |index| "10.1234/#{index}" }
    first_batch = dois.first(100)
    second_batch = dois.last(1)
    first_request = stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:#{first_batch.join('|')}"))
      .to_return(json_response(results: [{ "id" => "W1" }], next_cursor: nil))
    second_request = stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:#{second_batch.join('|')}"))
      .to_return(json_response(results: [{ "id" => "W2" }], next_cursor: nil))

    works = OpenAlexApiClient.new(api_key: "test-key").works_by_dois(dois)

    assert_equal [{ "id" => "W1" }, { "id" => "W2" }], works
    assert_requested first_request, times: 1
    assert_requested second_request, times: 1
  end

  test "normalizes README punctuation without changing balanced DOI parentheses" do
    client = OpenAlexApiClient.new(api_key: "test-key")

    assert_equal "10.5281/zenodo.15863068",
      client.normalize_doi("https://doi.org/10.5281/zenodo.15863068,")
    assert_equal "10.1088/1741-2560/13/1/016002",
      client.normalize_doi("10.1088/1741-2560/13/1/016002);")
    assert_equal "10.1016/0021-9991(92)90370-e",
      client.normalize_doi("10.1016/0021-9991(92)90370-e")
  end

  test "rejects README placeholders that are not DOIs" do
    client = OpenAlexApiClient.new(api_key: "test-key")

    assert_nil client.normalize_doi("fixme")
    assert_nil client.normalize_doi("concept_doi_from_zenodo")
  end

  def json_response(results:, next_cursor:)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "meta" => { "next_cursor" => next_cursor }, "results" => results }.to_json,
    }
  end
end
