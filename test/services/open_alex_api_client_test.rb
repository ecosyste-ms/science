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

  test "isolates and logs a DOI rejected with HTTP 400" do
    valid_dois = ["10.1000/one", "10.1000/two"]
    rejected_doi = '10.5281/zenodo.6581323[image:title="digital'
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "filter" => "doi:#{([valid_dois.first, rejected_doi, valid_dois.last]).join('|')}"
      ))
      .to_return(status: 400)
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:#{valid_dois.first}"))
      .to_return(json_response(results: [{ "id" => "W1" }], next_cursor: nil))
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "filter" => "doi:#{rejected_doi}|#{valid_dois.last}"
      ))
      .to_return(status: 400)
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:#{rejected_doi}"))
      .to_return(status: 400)
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:#{valid_dois.last}"))
      .to_return(json_response(results: [{ "id" => "W2" }], next_cursor: nil))

    _output, errors = capture_io do
      works = OpenAlexApiClient.new(api_key: "test-key").works_by_dois(
        [valid_dois.first, rejected_doi, valid_dois.last]
      )
      assert_equal [{ "id" => "W1" }, { "id" => "W2" }], works
    end

    assert_includes errors, "OpenAlex rejected a batch of 3 DOIs"
    assert_includes errors, "Skipping OpenAlex DOI #{rejected_doi.inspect}"
  end

  test "raises non-400 errors without splitting DOI batches" do
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including("filter" => "doi:10.1000/one|10.1000/two"))
      .to_return(status: 500)
    client = OpenAlexApiClient.new(api_key: "test-key")

    error = assert_raises(OpenAlexApiClient::RequestError) do
      client.works_by_dois(["10.1000/one", "10.1000/two"])
    end

    assert_equal 500, error.status
  end

  test "normalizes README punctuation without changing balanced DOI parentheses" do
    client = OpenAlexApiClient.new(api_key: "test-key")

    assert_equal "10.5281/zenodo.15863068",
      client.normalize_doi("https://doi.org/10.5281/zenodo.15863068,")
    assert_equal "10.1088/1741-2560/13/1/016002",
      client.normalize_doi("10.1088/1741-2560/13/1/016002);")
    assert_equal "10.1016/0021-9991(92)90370-e",
      client.normalize_doi("10.1016/0021-9991(92)90370-e")
    assert_equal "10.21105/joss.01453",
      client.normalize_doi("https://doi.org/10.21105%2Fjoss.01453")
  end

  test "rejects long retry delays without sleeping or issuing another request" do
    ["3600", 1.hour.from_now.httpdate].each do |retry_after|
      request = stub_request(:get, "https://api.openalex.org/works")
        .with(query: { "api_key" => "test-key" })
        .to_return(status: 429, headers: { "Retry-After" => retry_after })
      Faraday::Retry::Middleware.any_instance.expects(:sleep).never
      Rails.logger.expects(:warn).with("OpenAlex request failed: status=429")

      error = assert_raises(OpenAlexApiClient::RequestError) do
        OpenAlexApiClient.new(api_key: "test-key").get("works")
      end

      assert_equal 429, error.status
      assert_in_delta 1.hour.from_now.to_f, error.retry_at.to_f, 2
      assert_requested request, times: 1
      WebMock.reset!
    end
  end

  test "retains the later daily-credit reset when a rate limit response exhausts the allowance" do
    stub_request(:get, "https://api.openalex.org/works").with(query: { api_key: "test-key" })
      .to_return(status: 429, headers: { "Retry-After" => "3600", "X-RateLimit-Remaining" => "0", "X-RateLimit-Reset" => "7200" })
    Faraday::Retry::Middleware.any_instance.expects(:sleep).never
    error = assert_raises(OpenAlexApiClient::RequestError) { OpenAlexApiClient.new(api_key: "test-key").get("works") }
    assert_in_delta 2.hours.from_now.to_f, error.retry_at.to_f, 2
  end

  test "honors a short retry delay and logs only status and delay" do
    request = stub_request(:get, "https://api.openalex.org/works")
      .with(query: { "api_key" => "test-key" })
      .to_return(status: 429, headers: { "Retry-After" => "2" })
      .then.to_return(body: { results: [] }.to_json)
    Faraday::Retry::Middleware.any_instance.expects(:sleep).with(2.0)
    Rails.logger.expects(:warn).with("OpenAlex retry: status=429 delay_seconds=2.0")

    assert_equal({ "results" => [] }, OpenAlexApiClient.new(api_key: "test-key").get("works"))
    assert_requested request, times: 2
  end

  test "stops after two retries on persistent server errors" do
    request = stub_request(:get, "https://api.openalex.org/works")
      .with(query: { "api_key" => "test-key" }).to_return(status: 503)
    Faraday::Retry::Middleware.any_instance.expects(:sleep).twice.with { |delay| delay <= 5 }

    error = assert_raises(OpenAlexApiClient::RequestError) do
      OpenAlexApiClient.new(api_key: "test-key").get("works")
    end

    assert_equal 503, error.status
    assert_requested request, times: 3
  end

  test "rejects README placeholders that are not DOIs" do
    client = OpenAlexApiClient.new(api_key: "test-key")

    assert_nil client.normalize_doi("fixme")
    assert_nil client.normalize_doi("concept_doi_from_zenodo")
  end

  test "rejects DOI resolver image URLs" do
    client = OpenAlexApiClient.new(api_key: "test-key")

    assert_nil client.normalize_doi("https://doi.org/10.5281/zenodo.5565455.svg")
    assert_nil client.normalize_doi("https://doi.org/10.5281/zenodo.5565455.PNG")
    assert_nil client.normalize_doi("10.5281/zenodo.5565455.svg")
  end

  def json_response(results:, next_cursor:)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "meta" => { "next_cursor" => next_cursor }, "results" => results }.to_json,
    }
  end
end
