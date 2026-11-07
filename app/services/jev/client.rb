class Jev::Client
  PRICE_PER_MILLION = BigDecimal("0.042")
  API = "https://api.typesafe.ai/v1/systemone".freeze
  LOCK_NAMESPACE = 7_349_411
  BUDGET_LOCK = 7_349_412
  class Error < StandardError; end
  class BudgetExceeded < Error; end
  class Unavailable < Error; end
  class ConfigurationError < Error; end

  def initialize(run)
    @run = run
  end

  def self.fingerprint(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def self.canonical(value)
    case value
    when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def call(stage:, state:, replicate: nil)
    payload = self.class.canonical({ "model" => @run.settings.fetch("model"), "state" => state, "questions" => Jev::Questions.for(stage) })
    body = JSON.generate(payload)
    raise Error, "Jev input exceeds 24 KB" if body.bytesize > 24_000
    cache_digest = self.class.fingerprint([body, replicate])
    cached = Jev::Request.find_by(cache_digest: cache_digest, status: "succeeded")
    return cached if cached
    digest = Digest::SHA256.hexdigest("#{@run.id}:#{cache_digest}")
    Jev::Request.with_connection do |connection|
      lock_id = cache_digest[0, 7].to_i(16)
      acquired = connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{lock_id})")
      raise Jev::Limiter::Busy, "Identical Jev request in progress" unless acquired
      begin
        cached = Jev::Request.find_by(cache_digest: cache_digest, status: "succeeded")
        return cached if cached
        request = Jev::Request.create_or_find_by!(digest: digest) do |record|
          record.assign_attributes(run: @run, cache_digest: cache_digest, model: payload["model"], stage: stage,
            request_body: payload, wire_body: body, question_versions: Jev::Questions.versions(stage))
        end
        Jev::Limiter.with_slot("api") { evaluate(request, payload, body) }
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{lock_id})")
      end
    end
  end

  def evaluate(request, payload, body)
    raise ConfigurationError, "JEV_API_KEY is not configured" if ENV["JEV_API_KEY"].blank?
    reservation = ((body.bytesize + 4096) * PRICE_PER_MILLION / 1_000_000).round(8, BigDecimal::ROUND_CEILING)
    reserve!(request, reservation)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Faraday.new do |connection|
      connection.options.timeout = 25
      connection.options.open_timeout = 5
      connection.adapter :net_http
    end.post(API) do |http|
      http.headers["Authorization"] = "Bearer #{ENV.fetch('JEV_API_KEY')}"
      http.headers["Content-Type"] = "application/json"
      http.body = body
    end
    unless response.success?
      settle!(request, reservation, 0)
      request.update!(attempt_log: request.attempt_log + [{ "attempt" => request.attempts, "at" => Time.current.iso8601,
        "http_status" => response.status, "latency_ms" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 }])
      raise ConfigurationError, "Jev HTTP #{response.status}" if [401, 402, 403].include?(response.status)
      raise Unavailable, "Jev HTTP #{response.status}"
    end
    data = JSON.parse(response.body)
    tokens = data.dig("usage", "input_tokens")
    output = data.dig("usage", "output_tokens")
    raise Error, "Invalid Jev usage" unless tokens.is_a?(Integer) && tokens.between?(0, body.bytesize + 4096) && output.is_a?(Integer) && output >= 0
    cost = (tokens * PRICE_PER_MILLION / 1_000_000).round(8, BigDecimal::ROUND_CEILING)
    settle!(request, reservation, cost)
    latency = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    request.update!(input_tokens: request.input_tokens.to_i + tokens, output_tokens: request.output_tokens.to_i + output,
      latency_ms: latency, response_body: data, attempt_log: request.attempt_log + [
        { "attempt" => request.attempts, "at" => Time.current.iso8601, "latency_ms" => latency, "response" => data }])
    raise Error, "Unexpected Jev model" unless data["model"] == payload.fetch("model")
    payload.fetch("questions").each_key do |name|
      value = data.dig("answers", name, "noul")
      raise Error, "Invalid Jev probability" unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end
    request.update!(status: "succeeded", response_body: data, last_error: nil, completed_at: Time.current)
    request
  rescue Faraday::Error => error
    request.update!(status: "failed", last_error: "Jev connection failed: #{error.class}",
      attempt_log: request.attempt_log + [{ "attempt" => request.attempts, "at" => Time.current.iso8601, "error" => error.class.name }])
    raise Unavailable, "Jev connection failed: #{error.class}"
  rescue JSON::ParserError
    request.update!(status: "failed", last_error: "Invalid Jev JSON",
      attempt_log: request.attempt_log + [{ "attempt" => request.attempts, "at" => Time.current.iso8601, "error" => "Invalid Jev JSON" }])
    raise Error, "Invalid Jev JSON"
  rescue Error => error
    request.update!(status: "failed", last_error: error.message) unless error.is_a?(BudgetExceeded)
    raise
  end

  def reserve!(request, amount)
    Jev::Run.transaction do
      Jev::Run.connection.execute("SELECT pg_advisory_xact_lock(#{BUDGET_LOCK})")
      @run.reload
      total = Jev::Run.sum(:spent_usd) + Jev::Run.sum(:reserved_usd)
      raise BudgetExceeded, "Jev spending limit reached" if @run.spent_usd + @run.reserved_usd + amount > @run.budget_usd ||
        total + amount > Jev::Settings.decimal("TOTAL_BUDGET_USD", 5)
      @run.update!(reserved_usd: @run.reserved_usd + amount)
      request.update!(status: "running", attempts: request.attempts + 1, reserved_usd: request.reserved_usd + amount)
    end
  end

  def settle!(request, reservation, cost)
    Jev::Run.transaction do
      Jev::Run.connection.execute("SELECT pg_advisory_xact_lock(#{BUDGET_LOCK})")
      @run.reload
      @run.update!(reserved_usd: @run.reserved_usd - reservation, spent_usd: @run.spent_usd + cost)
      request.update!(reserved_usd: request.reserved_usd - reservation, cost_usd: request.cost_usd + cost)
    end
  end
end
