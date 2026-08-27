require "test_helper"

class FaradayInitializerTest < ActiveSupport::TestCase
  test "sets aggressive default timeouts" do
    connection = Faraday.new(url: "https://example.com")

    assert_equal 3, connection.options.open_timeout
    assert_equal 10, connection.options.timeout
    assert_equal 3, Faraday.default_connection.options.open_timeout
    assert_equal 10, Faraday.default_connection.options.timeout
  end

  test "default connection emits upstream metrics" do
    stub_request(:get, "https://direct.example.org/project").to_return(status: 200)
    Appsignal.expects(:increment_counter)
      .with("upstream_http_requests", 1, host: "direct.example.org", status: "200")
    Appsignal.expects(:add_distribution_value)
      .with("upstream_http_duration", anything, host: "direct.example.org")

    Faraday.get("https://direct.example.org/project")
  end
end
