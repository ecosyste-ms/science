class ProjectReleaseSync
  SOURCES = %w[tags releases].freeze
  PER_PAGE = 100
  REFRESH_AFTER = 1.day
  LEASE = 5.minutes

  class RequestError < StandardError
    attr_reader :retry_at

    def initialize(message, retry_at: nil)
      super(message)
      @retry_at = retry_at
    end
  end

  attr_reader :project, :source, :token, :state

  def initialize(project, source)
    raise ArgumentError, "unknown release source" unless SOURCES.include?(source)

    @project = project
    @source = source
  end

  def self.enqueue(project)
    SOURCES.each do |source|
      sync = new(project, source)
      SyncProjectReleasesWorker.perform_async(project.id, source) if sync.due?
    end
  end

  def source_url
    project.repository&.dig("#{source}_url").presence
  end

  def due?
    return false unless source_url

    current = project.release_sync_state.fetch(source, {})
    return true if current["url"] != source_url
    return false if current["started_at"] && Time.iso8601(current["started_at"]) > LEASE.ago

    current["retry_at"].blank? || Time.iso8601(current["retry_at"]) <= Time.current
  end

  def claim!
    project.with_lock do
      return false unless due?

      @state = project.release_sync_state.fetch(source, {}).dup
      @state = {} unless state["url"] == source_url
      @state = state.except("conflicts", "conflict_examples") if state.fetch("page", 1) == 1
      @token = SecureRandom.uuid
      @state = state.merge("url" => source_url, "page" => state.fetch("page", 1),
        "token" => token, "started_at" => Time.current.iso8601)
      store_state!
    end
    true
  end

  def sync!
    return unless claim!

    response = fetch_page
    records = JSON.parse(response.body)
    raise RequestError, "expected a list of #{source}" unless records.is_a?(Array)

    next_page = next_page(response, records)
    project.with_lock do
      return unless current_claim?

      records.each do |payload|
        Release.import!(project, source, payload)
      rescue Release::IdentityConflict => error
        @state["conflicts"] = state.fetch("conflicts", 0) + 1
        @state["conflict_examples"] ||= []
        @state["conflict_examples"] << error.message if state["conflict_examples"].length < 10
      end
      @state = state.except("token", "started_at", "error", "retry_at").merge(
        "page" => next_page || 1, "checked_at" => Time.current.iso8601
      )
      unless next_page
        @state["completed_at"] = Time.current.iso8601
        @state["retry_at"] = REFRESH_AFTER.from_now.iso8601
      end
      store_state!
    end
    if state.fetch("conflicts", 0).positive?
      Rails.logger.warn("Release identity conflicts for project #{project.id} (#{source}): #{state['conflict_examples'].inspect}")
    end
    SyncProjectReleasesWorker.perform_async(project.id, source) if next_page
  rescue RequestError, Faraday::Error, JSON::ParserError, ArgumentError,
      ActiveRecord::RecordInvalid => error
    record_error!(error)
  end

  def fetch_page
    connection = project.ecosystem_http_client(state.fetch("url"))
    connection.options.open_timeout = 5
    connection.options.timeout = 20
    response = connection.get do |request|
      request.params.update(per_page: PER_PAGE, page: state.fetch("page"), sort: "id", order: "asc")
    end
    unless response.success?
      raise RequestError.new("#{source} request returned HTTP #{response.status}",
        retry_at: retry_after(response.headers["retry-after"]))
    end
    response
  end

  def next_page(response, records)
    link = response.headers["link"]
    if link.present?
      following = link.split(",").find { |entry| entry.match?(/;\s*rel=["']?next["']?(?:\s|;|$)/) }
      return unless following

      url = following[/<([^>]+)>/, 1]
      raise RequestError, "invalid next link for #{source}" unless url

      page = URI.decode_www_form(URI.parse(url).query.to_s).to_h["page"].to_i
      raise RequestError, "invalid next page for #{source}" unless page == state.fetch("page") + 1

      page
    elsif records.length >= PER_PAGE
      state.fetch("page") + 1
    end
  rescue URI::InvalidURIError => error
    raise RequestError, "invalid next link for #{source}: #{error.message}"
  end

  def retry_after(value)
    return 1.hour.from_now if value.blank?
    return [value.to_i.seconds.from_now, 1.minute.from_now].max if value.match?(/\A\d+\z/)

    [Time.httpdate(value), 1.minute.from_now].max
  rescue ArgumentError
    1.hour.from_now
  end

  def current_claim?
    project.release_sync_state.dig(source, "token") == token && source_url == state["url"]
  end

  def store_state!
    project.update_columns(release_sync_state: project.release_sync_state.merge(source => state))
  end

  def record_error!(error)
    return unless token

    retry_at = error.respond_to?(:retry_at) && error.retry_at || 1.hour.from_now
    project.with_lock do
      return unless current_claim?

      @state = state.except("token", "started_at").merge(
        "error" => "#{error.class}: #{error.message}".truncate(1_000),
        "retry_at" => retry_at.iso8601
      )
      store_state!
    end
    Rails.logger.warn("Release sync failed for project #{project.id} (#{source}): #{state['error']}")
    SyncProjectReleasesWorker.perform_at(retry_at, project.id, source)
  end
end
