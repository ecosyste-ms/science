class SwhidArchiveChecker
  ENDPOINT = "https://archive.softwareheritage.org/api/1/known/"
  REFRESH_AFTER = 7.days
  RETRY_AFTER = 1.hour

  attr_reader :data

  def initialize(data)
    @data = (data || {}).deep_dup
  end

  def due?
    due_objects.any?
  end

  def due_objects
    objects.select do |object|
      archive = object["archive"] || {}
      timestamp = archive["status"] == "error" ? archive["attempted_at"] : archive["checked_at"]
      interval = archive["status"] == "error" ? RETRY_AFTER : REFRESH_AFTER
      timestamp.blank? || Time.iso8601(timestamp) <= Time.current - interval
    end
  end

  def objects
    data.values_at("revision", "directory").select do |object|
      object.is_a?(Hash) && object["status"] == "success" && object["swhid"].present?
    end
  end

  def self.client(url)
    Faraday.new(url: url) do |connection|
      connection.headers["User-Agent"] = "science.ecosyste.ms (+https://science.ecosyste.ms)"
      connection.headers["Authorization"] = "Bearer #{ENV['SWH_API_TOKEN']}" if ENV["SWH_API_TOKEN"].present?
      connection.headers["Accept"] = "application/json"
      connection.headers["Content-Type"] = "application/json"
      connection.options.open_timeout = 3
      connection.options.timeout = 10
      connection.request :instrumentation
      connection.adapter Faraday.default_adapter
    end
  end

  def check(force: false)
    pending = force ? objects : due_objects
    return data if pending.empty?

    attempted_at = Time.current.iso8601
    response = self.class.client(ENDPOINT).post { |request| request.body = pending.map { |object| object["swhid"] }.uniq.to_json }
    unless response.success?
      record_error(pending, "HTTP #{response.status}", attempted_at)
      return data
    end

    results = JSON.parse(response.body)
    pending.each do |object|
      entry = results.is_a?(Hash) ? results[object["swhid"]] : nil
      known = entry.is_a?(Hash) ? entry["known"] : nil
      if known == true || known == false
        archive = object["archive"] || {}
        archive["first_check"] ||= { "known" => known, "checked_at" => Time.current.iso8601 }
        object["archive"] = archive.except("error", "attempted_at").merge(
          "status" => known ? "archived" : "not_found",
          "checked_at" => Time.current.iso8601
        )
      else
        record_error([object], "Invalid archive response", attempted_at)
      end
    end
    data
  rescue Faraday::Error, JSON::ParserError => error
    record_error(pending, error.message, attempted_at)
    data
  end

  def record_error(objects, message, attempted_at)
    objects.each do |object|
      object["archive"] = (object["archive"] || {}).except("checked_at").merge(
        "status" => "error",
        "attempted_at" => attempted_at,
        "error" => message.to_s.scrub[0, 500]
      )
    end
  end
end
