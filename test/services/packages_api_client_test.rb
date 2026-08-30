require "test_helper"

class PackagesApiClientTest < ActiveSupport::TestCase
  test "fetches the bounded registry list" do
    connection = mock
    connection.expects(:get)
      .with("registries", per_page: 1_000)
      .returns(response([{ "name" => "rubygems.org" }], total_count: 1))

    registries = PackagesApiClient.new(connection: connection).registries

    assert_equal [{ "name" => "rubygems.org" }], registries
  end

  test "rejects a registry list larger than the limit" do
    connection = mock
    connection.expects(:get)
      .with("registries", per_page: 100)
      .returns(response([], total_count: 101))

    error = assert_raises(PackagesApiClient::RequestError) do
      PackagesApiClient.new(connection: connection).registries(limit: 100)
    end

    assert_equal "packages.ecosyste.ms has more than 100 registries", error.message
  end

  test "raises a request error for an unsuccessful response" do
    connection = mock
    connection.expects(:get).returns(response([], status: 503))

    error = assert_raises(PackagesApiClient::RequestError) do
      PackagesApiClient.new(connection: connection).registries
    end

    assert_equal "packages.ecosyste.ms request failed with HTTP 503", error.message
  end

  test "rejects an incomplete registry list" do
    connection = mock
    connection.expects(:get)
      .returns(response([{ "name" => "rubygems.org" }], total_count: 2))

    error = assert_raises(PackagesApiClient::RequestError) do
      PackagesApiClient.new(connection: connection).registries
    end

    assert_equal(
      "packages.ecosyste.ms returned an incomplete registry list",
      error.message
    )
  end

  def response(body, total_count: 0, status: 200)
    stub(
      success?: status.between?(200, 299),
      status: status,
      body: body.to_json,
      headers: { "total-count" => total_count.to_s }
    )
  end
end
