require "net/http"
require "timeout"

class HuggingFaceFileClient
  class RequestError < StandardError; end

  def get(url, limit:)
    Timeout.timeout(30) { request(URI.parse(url), limit: limit, redirects: 4) }
  rescue Timeout::Error, SocketError, SystemCallError, IOError, EOFError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError => error
    raise RequestError, "Hub request failed: #{error.class}"
  rescue URI::InvalidURIError
    raise RequestError, "Invalid Hub URL"
  end

  def request(uri, limit:, redirects:)
    unless uri.scheme == "https" && uri.host == "huggingface.co" && uri.port == 443 && uri.userinfo.nil?
      raise RequestError, "Expected an HTTPS huggingface.co URL"
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    http.max_retries = 0
    response = nil
    body = +"".b
    http.start do |connection|
      connection.request(Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "science.ecosyste.ms")) do |reply|
        response = reply
        raise RequestError, "Hub response exceeds #{limit / 1.megabyte} MB" if reply["content-length"].to_i > limit

        reply.read_body do |chunk|
          raise RequestError, "Hub response exceeds #{limit / 1.megabyte} MB" if body.bytesize + chunk.bytesize > limit

          body << chunk
        end
      end
    end
    if response.is_a?(Net::HTTPRedirection)
      raise RequestError, "Too many Hub redirects" if redirects.zero?
      raise RequestError, "Hub redirect has no location" if response["location"].blank?

      return request(URI.join(uri.to_s, response["location"]), limit: limit, redirects: redirects - 1)
    end
    { "status" => response.code.to_i, "body" => body, "resolved_url" => uri.to_s,
      "retry_after" => response["retry-after"] }.compact
  end
end
