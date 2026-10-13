require "test_helper"
require "socket"
require "stringio"

class FaradayInitializerTest < ActiveSupport::TestCase
  test "real HTTP requests filter credentials in Ethon logs without changing the request" do
    assert_instance_of FilteredHttpLogger, Ethon.logger
    original_logger = Ethon.logger
    output = StringIO.new
    Ethon.logger = FilteredHttpLogger.new(Logger.new(output), filters: Rails.application.config.filter_parameters)
    server = TCPServer.new("127.0.0.1", 0)
    received = nil
    thread = Thread.new do
      socket = server.accept
      received = socket.gets
      while (line = socket.gets)
        break if line == "\r\n"
      end
      socket.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
      socket.close
    end
    response = Faraday.get("http://127.0.0.1:#{server.addr[1]}/works?api_key=test-secret&access_token=test-token&q=bert")
    thread.join
    assert_equal 200, response.status
    assert_includes received, "api_key=test-secret"
    assert_includes output.string, "api_key=[FILTERED]"
    assert_includes output.string, "access_token=[FILTERED]"
    assert_includes output.string, "q=bert"
    refute_includes output.string, "test-secret"
    refute_includes output.string, "test-token"
  ensure
    thread&.kill
    server&.close
    Ethon.logger = original_logger if original_logger
  end

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
