class SwhidOriginChecker
  ENDPOINT = "https://archive.softwareheritage.org/api/1/origin/"
  REFRESH_AFTER = 7.days
  RETRY_AFTER = 1.hour
  MAX_ORIGINS = 8
  MAX_PAGES = 3
  MAX_REQUESTS = 10

  class ResponseError < StandardError; end

  attr_reader :project

  def initialize(project)
    @project = project
  end

  def origins
    repository = project.repository || {}
    urls = [project.swhids&.dig("origin"), project.url, repository["clone_url"], repository["html_url"]]
    host = RepositoryUrlNormalizer.parse(project.url)&.host
    if host && repository["previous_names"].is_a?(Array)
      urls.concat(repository["previous_names"].map { |name| name.to_s.include?("://") ? name : "https://#{host}/#{name}" })
    end
    urls.concat(project.repository_aliases.pluck(:url))
    urls.concat(ProjectRepositoryAliasIndexer.new(project).repository_alias_urls)
    urls.flat_map do |url|
      uri = RepositoryUrlNormalizer.parse(url)
      next [] unless uri && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

      normalized = RepositoryUrlNormalizer.normalize(url)
      [(%w[http https].include?(uri.scheme) ? uri.to_s : nil), normalized, ("#{normalized}.git" if normalized)]
    end.compact.uniq
  end

  def due?(refresh_after: REFRESH_AFTER)
    previous = project.swhids&.dig("origin_archive")
    return true unless previous && previous["origins"] == origins
    return Time.iso8601(previous["retry_at"]) <= Time.current if previous["retry_at"]

    interval = previous["status"] == "unknown" ? RETRY_AFTER : refresh_after
    observations = Array(previous["observations"])
    timestamps = observations.filter_map { |entry| entry["checked_at"] }
    checked_at = if previous["status"] == "archived"
      observations.select { |entry| entry["status"] == "archived" }.filter_map { |entry| entry["checked_at"] }.max
    elsif previous["status"] == "not_found"
      timestamps.min
    end
    Time.iso8601(checked_at || previous.fetch("checked_at")) <= Time.current - interval
  end

  def check(refresh_after: REFRESH_AFTER, force: false)
    return project.swhids&.dig("origin_archive") unless force || due?(refresh_after: refresh_after)

    SwhidApi.check_rate_limit!
    @remaining_requests = MAX_REQUESTS
    @origins = origins
    @previous = project.swhids&.dig("origin_archive")&.deep_dup
    @request = project.swhids&.dig("archival")&.deep_dup
    cutoff = Time.iso8601(@request.fetch("attempted_at")) if @request&.dig("id") &&
      @request.dig("repository_before_request", "classification").to_s.in?(["", "unknown"])
    observations = saved_observations(cutoff)
    pending_origins(observations, refresh_after: refresh_after, force: force).first(MAX_ORIGINS).each do |origin|
      break if @remaining_requests <= 0

      observation = observations.find { |entry| entry["origin"] == origin }
      unless observation
        observation = { "origin" => origin, "status" => "unknown" }
        observations << observation
      end
      lookup(observation, cutoff)
      break if observation["lookup_complete"] && observation["status"] == "archived" && (!cutoff || observation["prior_visit"])
    end
    persist(observations, cutoff)
  rescue SwhidApi::RateLimited => error
    if observations
      persist(observations, cutoff, retry_at: error.retry_at)
    end
    raise
  end

  def saved_observations(cutoff)
    Array(@previous&.dig("observations")).filter_map do |entry|
      next unless @origins.include?(entry["origin"])

      observation = entry.deep_dup
      observation["checked_at"] ||= @previous["checked_at"] unless observation["attempted_at"]
      observation["lookup_complete"] = observation["status"] != "unknown" && !observation["error"] unless observation.key?("lookup_complete")
      if cutoff && observation["history_cutoff"] != cutoff.iso8601
        observation.delete("next_visit")
        observation.delete("prior_visit")
        if observation["visit"] && Time.iso8601(observation["visit"]["date"]) < cutoff
          observation["prior_visit"] = observation["visit"].deep_dup
        elsif observation["status"] == "archived"
          observation["lookup_complete"] = false
        end
      end
      observation
    end
  end

  def pending_origins(observations, refresh_after:, force:)
    indexed = observations.index_by { |entry| entry["origin"] }
    @origins.select do |origin|
      entry = indexed[origin]
      !entry || !entry["lookup_complete"] || force || Time.iso8601(entry["checked_at"]) <= Time.current - refresh_after
    end.sort_by do |origin|
      entry = indexed[origin]
      [entry ? (entry["lookup_complete"] ? 2 : 1) : 0,
        entry&.dig("attempted_at") || entry&.dig("checked_at") || "", @origins.index(origin)]
    end
  end

  def lookup(observation, cutoff)
    origin = observation.fetch("origin")
    observation.delete("next_visit") if observation["lookup_complete"]
    observation.delete("error")
    observation["attempted_at"] = Time.current.iso8601
    observation["lookup_complete"] = false
    observation["history_complete"] = false
    observation["history_cutoff"] = cutoff&.iso8601
    url = "#{ENDPOINT}#{ERB::Util.url_encode(origin)}/visits/"
    params = { "per_page" => 100 }
    params["last_visit"] = observation["next_visit"] if observation["next_visit"]
    MAX_PAGES.times do
      raise ResponseError, "Origin lookup request limit reached" if @remaining_requests <= 0

      @remaining_requests -= 1
      response = SwhidApi.request(:get, url, params: params)
      if response.status == 404
        return finish_lookup(observation, history_complete: true)
      end
      raise ResponseError, "HTTP #{response.status}" unless response.success?

      visits = JSON.parse(response.body)
      raise ResponseError, "Invalid origin visits response" unless visits.is_a?(Array)

      visits.each { |visit| validate_visit(visit, origin) }
      visits.each do |visit|
        next unless visit["snapshot"].present? && %w[full partial].include?(visit["status"])

        evidence = visit.slice("date", "visit", "snapshot", "status", "type")
        if !observation["visit"] || Time.iso8601(evidence["date"]) > Time.iso8601(observation["visit"]["date"])
          observation["visit"] = evidence
        end
        observation["status"] = "archived"
        observation["prior_visit"] ||= evidence if cutoff && Time.iso8601(visit["date"]) < cutoff
      end
      params = next_page(response.headers["link"], url)
      return finish_lookup(observation, history_complete: true) unless params

      observation["next_visit"] = params["last_visit"]
      if observation["visit"] && (!cutoff || observation["prior_visit"])
        return finish_lookup(observation, history_complete: false)
      end
    end
    observation["error"] = "Origin visit history limit reached"
    observation
  rescue SwhidApi::RateLimited => error
    observation["error"] = error.message
    raise
  rescue Faraday::Error, JSON::ParserError, ResponseError, ArgumentError, URI::Error => error
    observation["error"] = error.message.to_s.scrub[0, 500]
    observation
  end

  def finish_lookup(observation, history_complete:)
    observation["status"] = observation["visit"] ? "archived" : "not_found"
    observation["checked_at"] = Time.current.iso8601
    observation["lookup_complete"] = true
    observation["history_complete"] = history_complete
    observation.delete("next_visit")
    observation
  end

  def validate_visit(visit, origin)
    unless visit.is_a?(Hash) && visit["origin"] == origin && visit["date"].is_a?(String) &&
        visit["visit"].is_a?(Integer) && visit["visit"].positive? && visit["type"].is_a?(String) &&
        %w[created ongoing full partial not_found failed].include?(visit["status"]) &&
        (visit["snapshot"].nil? || visit["snapshot"].is_a?(String) && visit["snapshot"].match?(/\A[0-9a-f]{40}\z/))
      raise ResponseError, "Invalid origin visit"
    end
    raise ResponseError, "Full visit has no snapshot" if visit["status"] == "full" && visit["snapshot"].nil?

    Time.iso8601(visit.fetch("date"))
  end

  def next_page(header, url)
    link = header.to_s.split(",").find { |part| part.match?(/;\s*rel="?next"?(?:\s|;|\z)/) }
    return unless link

    target = URI.join(url, link[/<([^>]+)>/, 1].to_s)
    expected = URI.parse(url)
    unless target.scheme == expected.scheme && target.host == expected.host && target.port == expected.port &&
        target.userinfo.nil? && URI.decode_www_form_component(target.path) == URI.decode_www_form_component(expected.path)
      raise ResponseError, "Invalid origin pagination link"
    end
    params = URI.decode_www_form(target.query.to_s).to_h
    raise ResponseError, "Missing origin pagination cursor" if params["last_visit"].blank?

    params.slice("last_visit").merge("per_page" => 100)
  end

  def persist(observations, cutoff, retry_at: nil)
    observations.sort_by! { |entry| @origins.index(entry["origin"]) }
    archived = observations.find { |entry| entry["status"] == "archived" }
    unchecked = @origins - observations.pluck("origin")
    complete = unchecked.empty? && observations.all? { |entry| entry["lookup_complete"] }
    absent = @origins.any? && complete && observations.all? { |entry| entry["status"] == "not_found" }
    result = {
      "status" => archived ? "archived" : (absent ? "not_found" : "unknown"),
      "checked_at" => Time.current.iso8601, "origins" => @origins, "observations" => observations,
      "complete" => complete, "unchecked_origins" => unchecked
    }
    covered = observations.any? { |entry| entry["lookup_complete"] && entry["visit"] && (!cutoff || entry["prior_visit"]) }
    retry_at ||= Time.current + RETRY_AFTER unless covered || complete
    result["retry_at"] = retry_at.iso8601 if retry_at
    project.with_lock do
      data = (project.swhids || {}).deep_dup
      next unless data["origin_archive"] == @previous && origins == @origins

      data["origin_archive"] = result
      request = data["archival"]
      prior = observations.find { |entry| entry["prior_visit"] }
      if cutoff && prior && request&.slice("id", "attempted_at") == @request.slice("id", "attempted_at") &&
          request.dig("repository_before_request", "classification").to_s.in?(["", "unknown"])
        request["repository_before_request"] = {
          "classification" => "missing_versions", "basis" => "visit_history", "cutoff" => cutoff.iso8601,
          "checked_at" => result["checked_at"], "origin" => prior["origin"], "visit" => prior["prior_visit"]
        }
      end
      project.update!(swhids: data)
    end
    result
  end

  def self.before_submission(coverage)
    classification = "unknown"
    if coverage && Time.iso8601(coverage.fetch("checked_at")) > 5.minutes.ago
      observations = Array(coverage["observations"])
      fresh = observations.select do |entry|
        Time.iso8601(entry["checked_at"] || coverage["checked_at"]) > 5.minutes.ago && entry["lookup_complete"] != false
      end
      if coverage["status"] == "archived" && fresh.any? { |entry| entry["status"] == "archived" }
        classification = "missing_versions"
      elsif coverage["status"] == "not_found" && fresh.size == observations.size
        classification = "missing_repository"
      end
    end
    { "classification" => classification, "basis" => "pre_submission", "coverage" => coverage&.deep_dup }
  end
end
