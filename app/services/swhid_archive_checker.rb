class SwhidArchiveChecker
  ENDPOINT = "https://archive.softwareheritage.org/api/1/known/"
  REFRESH_AFTER = 7.days
  RETRY_AFTER = 1.hour
  MAX_IDENTIFIERS = 1_000

  attr_reader :data, :rate_limit

  def initialize(data)
    @data = (data || {}).deep_dup
  end

  def due?
    due_objects.any?
  end

  def due_objects
    objects.select do |object|
      archive = object["archive"] || {}
      next Time.iso8601(archive["retry_at"]) <= Time.current if archive["retry_at"].present?

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

  def check(force: false)
    pending = force ? objects : due_objects
    self.class.check_batch([[self, pending]])
    data
  end

  def self.check_batch(checks)
    identifiers = checks.flat_map { |_, objects| objects.map { |object| object.fetch("swhid") } }.uniq
    return if identifiers.empty?
    raise ArgumentError, "Too many SWHIDs" if identifiers.size > MAX_IDENTIFIERS

    attempted_at = Time.current.iso8601
    response = SwhidApi.request(:post, ENDPOINT, body: identifiers.to_json)
    unless response.success?
      checks.each { |checker, objects| checker.record_error(objects, "HTTP #{response.status}", attempted_at) }
      return
    end

    results = JSON.parse(response.body)
    checks.each { |checker, objects| checker.record_results(objects, results, attempted_at) }
  rescue SwhidApi::RateLimited => error
    checks.each { |checker, objects| checker.record_rate_limit(objects, error, attempted_at) }
  rescue Faraday::Error, JSON::ParserError => error
    checks.each { |checker, objects| checker.record_error(objects, error.message, attempted_at) }
  end

  def record_results(pending, results, attempted_at)
    pending.each do |object|
      entry = results.is_a?(Hash) ? results[object["swhid"]] : nil
      known = entry.is_a?(Hash) ? entry["known"] : nil
      if known == true || known == false
        archive = object["archive"] || {}
        archive["first_check"] ||= { "known" => known, "checked_at" => Time.current.iso8601 }
        object["archive"] = archive.except("error", "attempted_at", "retry_at").merge(
          "status" => known ? "archived" : "not_found",
          "checked_at" => Time.current.iso8601
        )
      else
        record_error([object], "Invalid archive response", attempted_at)
      end
    end
  end

  def record_rate_limit(pending, error, attempted_at)
    @rate_limit = error
    record_error(pending, error.message, attempted_at)
    pending.each { |object| object["archive"]["retry_at"] = error.retry_at.iso8601 }
  end

  def record_error(objects, message, attempted_at)
    objects.each do |object|
      object["archive"] = (object["archive"] || {}).except("checked_at", "retry_at").merge(
        "status" => "error",
        "attempted_at" => attempted_at,
        "error" => message.to_s.scrub[0, 500]
      )
    end
  end
end
