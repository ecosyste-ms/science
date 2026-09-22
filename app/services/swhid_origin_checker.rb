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
    Time.iso8601(previous.fetch("checked_at")) <= Time.current - interval
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
    observations = []
    @origins.first(MAX_ORIGINS).each do |origin|
      @current_origin = origin
      observations << lookup(origin, cutoff)
      break if observations.last["status"] == "archived" && (!cutoff || observations.last["prior_visit"])
    end
    persist(observations, cutoff)
  rescue SwhidApi::RateLimited => error
    if observations
      observations << { "origin" => @current_origin, "status" => "unknown", "error" => error.message }
      persist(observations, cutoff, retry_at: error.retry_at)
    end
    raise
  end

  def lookup(origin, cutoff)
    observation = { "origin" => origin, "status" => "unknown" }
    url = "#{ENDPOINT}#{ERB::Util.url_encode(origin)}/visits/"
    params = { per_page: 100 }
    MAX_PAGES.times do
      raise ResponseError, "Origin lookup request limit reached" if @remaining_requests <= 0

      @remaining_requests -= 1
      response = SwhidApi.request(:get, url, params: params)
      if response.status == 404
        observation["status"] = "not_found" unless observation["visit"]
        return observation
      end
      raise ResponseError, "HTTP #{response.status}" unless response.success?

      visits = JSON.parse(response.body)
      raise ResponseError, "Invalid origin visits response" unless visits.is_a?(Array)

      visits.each do |visit|
        validate_visit(visit, origin)
        next unless visit["snapshot"].present? && %w[full partial].include?(visit["status"])

        evidence = visit.slice("date", "visit", "snapshot", "status", "type")
        observation["visit"] ||= evidence
        observation["status"] = "archived"
        observation["prior_visit"] ||= evidence if cutoff && Time.iso8601(visit["date"]) < cutoff
      end
      return observation if observation["visit"] && (!cutoff || observation["prior_visit"])

      params = next_page(response.headers["link"], url)
      unless params
        observation["status"] = "not_found" unless observation["visit"]
        return observation
      end
    end
    observation.merge("error" => "Origin visit history limit reached")
  rescue Faraday::Error, JSON::ParserError, ResponseError, ArgumentError, URI::Error => error
    observation.merge("error" => error.message.to_s.scrub[0, 500])
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
    archived = observations.find { |entry| entry["status"] == "archived" }
    absent = @origins.any? && observations.size == @origins.size && observations.all? { |entry| entry["status"] == "not_found" }
    result = {
      "status" => archived ? "archived" : (absent ? "not_found" : "unknown"),
      "checked_at" => Time.current.iso8601, "origins" => @origins, "observations" => observations
    }
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
      classification = { "archived" => "missing_versions", "not_found" => "missing_repository" }.fetch(coverage["status"], "unknown")
    end
    { "classification" => classification, "basis" => "pre_submission", "coverage" => coverage&.deep_dup }
  end
end
