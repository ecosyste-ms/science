require "test_helper"

class ReposApiClientTest < ActiveSupport::TestCase
  test "collects GitLab host URLs across every host page" do
    connection = mock
    connection.expects(:get)
      .with("hosts", per_page: 100, page: 1)
      .returns(response(
        [
          { "kind" => "github", "url" => "https://github.com" },
          { "kind" => "gitlab", "url" => "https://gitlab.com" },
        ],
        total_pages: 2
      ))
    connection.expects(:get)
      .with("hosts", per_page: 100, page: 2)
      .returns(response(
        [{ "kind" => "gitlab", "url" => "https://salsa.debian.org" }],
        total_pages: 2
      ))

    hosts = ReposApiClient.new(connection: connection).gitlab_hosts

    assert_equal [
      "https://gitlab.com",
      "https://salsa.debian.org",
    ], hosts
  end

  test "raises a request error for an unsuccessful response" do
    connection = mock
    connection.expects(:get).returns(response([], status: 503))

    error = assert_raises(ReposApiClient::RequestError) do
      ReposApiClient.new(connection: connection).gitlab_hosts
    end

    assert_equal "repos.ecosyste.ms request failed with HTTP 503", error.message
  end

  def response(body, total_pages: 1, status: 200)
    stub(
      success?: status.between?(200, 299),
      status: status,
      body: body.to_json,
      headers: { "total-pages" => total_pages.to_s }
    )
  end
end
