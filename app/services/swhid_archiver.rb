class SwhidArchiver
  ENDPOINT = "https://archive.softwareheritage.org/api/1/origin/save/"
  POLL_INTERVAL = 6.hours
  POLL_LIMIT = 30.days
  REQUEST_STATUSES = %w[accepted pending rejected].freeze
  TASK_STATUSES = ["not created", "pending", "scheduled", "running", "succeeded", "failed"].freeze

  class ResponseError < StandardError; end

  attr_reader :project

  def initialize(project)
    @project = project
  end

  def due?
    request = project.swhids&.dig("archival")
    if request
      return true if request["status"] == "uncertain" && retryable_submission?(request)

      %w[submitting pending rate_limited].include?(request["status"]) && Time.iso8601(request.fetch("next_check_at")) <= Time.current
    else
      origin = URI.parse(project.swhids&.dig("origin").to_s)
      %w[http https].include?(origin.scheme) && origin.host.present? &&
        SwhidArchiveChecker.new(project.swhids).objects.any? { |object| object.dig("archive", "status") == "not_found" }
    end
  rescue URI::InvalidURIError
    false
  end

  def run
    return unless due?

    SwhidApi.check_rate_limit!
    previous = project.swhids["archival"]
    return if (previous.nil? || retryable_submission?(previous)) && !prepare_submission

    request = claim
    return unless request

    if request["status"] == "submitting"
      response = SwhidApi.request(:post, ENDPOINT, params: { visit_type: "git", origin_url: request.fetch("origin") })
      result = parse_response(response, request)
      request["attribution_eligible"] = Time.iso8601(result.fetch("save_request_date")) >= Time.iso8601(request.fetch("attempted_at"))
    else
      response = SwhidApi.request(:get, "#{ENDPOINT}#{request.fetch('id')}/")
      result = parse_response(response, request)
    end

    request.merge!(result.slice("id", "save_request_date", "save_request_status", "save_task_status", "visit_status"))
    request.delete("error")
    request.delete("retry_at")
    request["status"] = if result["save_request_status"] == "rejected"
      "rejected"
    elsif result["save_task_status"] == "failed"
      "failed"
    else
      "pending"
    end
    confirm(request) if request["status"] == "pending" && result["save_task_status"] == "succeeded"
    persist(request)
  rescue SwhidApi::RateLimited => error
    retry_at = SwhidApi.retry_job_at(error)
    if request
      request["status"] = request["id"] ? "pending" : "rate_limited"
      request["error"] = error.message
      request["retry_at"] = error.retry_at.iso8601
      request["next_check_at"] = retry_at.iso8601
      persist(request)
    else
      CheckSwhidWorker.perform_at(retry_at, project.id)
    end
  rescue Faraday::Error, JSON::ParserError, ResponseError, ArgumentError => error
    raise unless request

    request["status"] = "uncertain" if request["status"] == "submitting"
    request["error"] = error.message.to_s.scrub[0, 500]
    persist(request)
  end

  def retryable_submission?(request)
    request["id"].blank? && (request["status"] == "rate_limited" || (request["status"] == "uncertain" && request["error"] == "HTTP 429"))
  end

  def prepare_submission
    checker = SwhidArchiveChecker.new(project.swhids)
    if project.swhids["archival"] || checker.objects.any? { |object| object.dig("archive", "checked_at").blank? || Time.iso8601(object.dig("archive", "checked_at")) <= 5.minutes.ago }
      project.check_swhid_archive(force: true)
    end
    objects = SwhidArchiveChecker.new(project.swhids).objects
    if objects.all? { |object| %w[archived not_found].include?(object.dig("archive", "status")) }
      if objects.any? { |object| object.dig("archive", "status") == "not_found" }
        SwhidOriginChecker.new(project).check(refresh_after: project.swhids["archival"] ? 0.seconds : 5.minutes)
      end
      return true
    end

    CheckSwhidWorker.perform_in(1.hour, project.id)
    false
  end

  def claim
    project.with_lock do
      return unless due?

      data = project.swhids.deep_dup
      request = data["archival"]
      if request
        if request["status"] == "submitting" || Time.iso8601(request["first_attempted_at"] || request["attempted_at"]) <= Time.current - POLL_LIMIT
          request["status"] = request["status"] == "submitting" ? "uncertain" : "expired"
          project.update!(swhids: data)
          return
        end
      end
      if request.nil? || retryable_submission?(request)
        objects = SwhidArchiveChecker.new(data).objects
        return unless objects.all? { |object| %w[archived not_found].include?(object.dig("archive", "status")) }

        missing = objects.select { |object| object.dig("archive", "status") == "not_found" }
        if missing.empty?
          if request
            request["status"] = "not_needed"
            project.update!(swhids: data)
          end
          return
        end

        first_attempt = request&.dig("first_attempted_at") || request&.dig("attempted_at") || Time.current.iso8601
        coverage = data["origin_archive"]
        coverage = nil unless coverage && coverage["origins"] == SwhidOriginChecker.new(project).origins
        request = (request || {}).merge(
          "status" => "submitting", "origin" => data.fetch("origin"), "attempted_at" => Time.current.iso8601,
          "first_attempted_at" => first_attempt,
          "repository_before_request" => SwhidOriginChecker.before_submission(coverage),
          "before_request" => missing.to_h { |object| [object.fetch("swhid"), { "known" => false, "checked_at" => object.dig("archive", "checked_at") }] }
        )
      end
      request["next_check_at"] = (Time.current + POLL_INTERVAL).iso8601
      data["archival"] = request
      project.update!(swhids: data)
      request.deep_dup
    end
  end

  def parse_response(response, request)
    raise ResponseError, "HTTP #{response.status}" unless response.success?

    result = JSON.parse(response.body)
    unless result.is_a?(Hash) && result["id"].is_a?(Integer) && result["id"].positive? &&
        result["origin_url"] == request["origin"] && result["visit_type"] == "git" &&
        REQUEST_STATUSES.include?(result["save_request_status"]) && TASK_STATUSES.include?(result["save_task_status"]) &&
        result["save_request_date"].is_a?(String) && (!request["id"] || result["id"] == request["id"])
      raise ResponseError, "Invalid archival response"
    end
    Time.iso8601(result["save_request_date"])
    result
  end

  def confirm(request)
    project.check_swhid_archive(force: true)
    objects = SwhidArchiveChecker.new(project.swhids).objects.index_by { |object| object["swhid"] }
    identifiers = request.fetch("before_request").keys
    return unless identifiers.all? { |identifier| %w[archived not_found].include?(objects[identifier]&.dig("archive", "status")) }

    request["confirmed_swhids"] = if request["attribution_eligible"]
      identifiers.select { |identifier| objects[identifier].dig("archive", "status") == "archived" }
    else
      []
    end
    request["status"] = "completed"
    request["completed_at"] = Time.current.iso8601
  end

  def persist(request)
    saved = project.with_lock do
      data = project.swhids&.deep_dup
      next false unless data&.dig("archival", "attempted_at") == request["attempted_at"]

      data["archival"] = request
      project.update!(swhids: data)
      true
    end
    if saved && %w[pending rate_limited].include?(request["status"])
      CheckSwhidArchivalWorker.perform_at(Time.iso8601(request.fetch("next_check_at")), project.id)
    elsif saved && request["status"] == "completed"
      CheckSwhidOriginWorker.perform_async(project.id, true)
    end
  end

  def self.contribution_counts
    Project.with_connection do |connection|
      connection.select_one(<<~SQL).transform_values(&:to_i)
        SELECT COUNT(DISTINCT identifier) AS total,
               COUNT(DISTINCT identifier) FILTER (WHERE identifier LIKE 'swh:1:rev:%') AS revisions,
               COUNT(DISTINCT identifier) FILTER (WHERE identifier LIKE 'swh:1:dir:%') AS directories
        FROM projects
        CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(swhids->'archival'->'confirmed_swhids', '[]'::jsonb)) AS ids(identifier)
        WHERE swhids->'archival'->>'status' = 'completed'
          AND swhids->'archival'->>'attribution_eligible' = 'true'
      SQL
    end
  end
end
