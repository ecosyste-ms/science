require 'faraday/typhoeus'
Faraday.default_adapter = :typhoeus

Faraday.default_connection_options = {
  headers: {
    'User-Agent' => 'science.ecosyste.ms'
  },
  request: {
    timeout: 10,
    open_timeout: 3
  }
}

Faraday.default_connection = Faraday.new do |faraday|
  faraday.request :instrumentation
  faraday.adapter Faraday.default_adapter
end

ActiveSupport::Notifications.subscribe("request.faraday") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  env = event.payload
  host = env[:url].host
  status = env[:status] || 0
  Appsignal.increment_counter("upstream_http_requests", 1, host: host, status: status.to_s)
  Appsignal.add_distribution_value("upstream_http_duration", event.duration, host: host)
rescue => e
  Rails.logger.warn("request.faraday subscriber error: #{e.class} #{e.message}")
end
