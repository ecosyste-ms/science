module EcosystemApiClient
  extend ActiveSupport::Concern

  included do
    def http_client(url, headers: {}, retry_requests: false)
      Faraday.new(url: url) do |faraday|
        headers.each { |name, value| faraday.headers[name] = value }
        faraday.request :instrumentation
        faraday.response :follow_redirects
        if retry_requests
          faraday.request :retry,
            max: 1,
            interval: 0.5,
            interval_randomness: 0.5,
            backoff_factor: 2
        end
        faraday.adapter Faraday.default_adapter
      end
    end

    def ecosystem_http_client(url)
      headers = { 'User-Agent' => 'science.ecosyste.ms' }
      headers['X-API-Key'] = ENV['ECOSYSTEMS_API_KEY'] if ENV['ECOSYSTEMS_API_KEY']
      http_client(url, headers: headers)
    end
  end

  class_methods do
    def ecosystem_http_get(url)
      conn = Faraday.new(url: url) do |faraday|
        faraday.headers['User-Agent'] = 'science.ecosyste.ms'
        faraday.headers['X-API-Key'] = ENV['ECOSYSTEMS_API_KEY'] if ENV['ECOSYSTEMS_API_KEY']
        faraday.request :instrumentation
        faraday.response :follow_redirects
        faraday.adapter Faraday.default_adapter
      end
      conn.get
    end
  end
end
