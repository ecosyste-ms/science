class PackageVersionSync
  PER_PAGE = 100
  REFRESH_AFTER = 1.day
  LEASE = 5.minutes
  OVERLAP = 5.minutes

  class RequestError < StandardError
    attr_reader :retry_at

    def initialize(message, retry_at: nil)
      super(message)
      @retry_at = retry_at
    end
  end

  attr_reader :package, :client, :state, :token

  def initialize(package, client: PackagesApiClient.new(retry_requests: false))
    @package = package
    @client = client
  end

  def source_identity
    { "url" => package.metadata["versions_url"], "project_id" => package.published_by_project_id,
      "ecosystems_id" => package.ecosystems_id }
  end

  def due?
    return false unless Package.version_importable.exists?(package.id)

    current = package.version_sync_state
    return true unless current.slice(*source_identity.keys) == source_identity
    return false if current["started_at"] && Time.iso8601(current["started_at"]) > LEASE.ago

    current["retry_at"].blank? || Time.iso8601(current["retry_at"]) <= Time.current
  end

  def claim!
    package.with_lock do
      return false unless due?

      @state = package.version_sync_state.dup
      @state = {} unless state.slice(*source_identity.keys) == source_identity
      if state.fetch("page", 1) == 1
        @state = state.except("conflicts", "conflict_examples", "updated_after")
        @state["scan_started_at"] = Time.current.iso8601
        if state["synced_through"]
          @state["updated_after"] = (Time.iso8601(state["synced_through"]) - OVERLAP).iso8601
        end
      end
      @token = SecureRandom.uuid
      @state = state.merge(source_identity).merge(
        "page" => state.fetch("page", 1), "token" => token, "started_at" => Time.current.iso8601
      )
      store_state!
    end
    true
  end

  def sync!
    return unless claim!

    response = fetch_page
    records = JSON.parse(response.body)
    raise RequestError, "expected a list of versions" unless records.is_a?(Array)

    following_page = next_page(response, records)
    package.with_lock do
      return unless current_claim?

      records.each do |payload|
        PackageVersion.import!(package, payload)
      rescue PackageVersion::IdentityConflict => error
        @state["conflicts"] = state.fetch("conflicts", 0) + 1
        @state["conflict_examples"] ||= []
        @state["conflict_examples"] << error.message if state["conflict_examples"].length < 10
      end
      @state = state.except("token", "started_at", "error", "retry_at").merge(
        "page" => following_page || 1, "checked_at" => Time.current.iso8601
      )
      unless following_page
        @state = state.merge(
          "completed_at" => Time.current.iso8601,
          "retry_at" => REFRESH_AFTER.from_now.iso8601
        )
        @state["synced_through"] = state.fetch("scan_started_at") if state.fetch("conflicts", 0).zero?
      end
      store_state!
    end
    if state.fetch("conflicts", 0).positive?
      Rails.logger.warn("Version identity conflicts for package #{package.id}: #{state['conflict_examples'].inspect}")
    end
    SyncPackageVersionsWorker.perform_async(package.id) if following_page
  rescue RequestError, Faraday::Error, JSON::ParserError, ArgumentError,
      ActiveRecord::RecordInvalid => error
    record_error!(error)
  end

  def fetch_page
    uri = URI.parse(state.fetch("url"))
    unless uri.scheme == "https" && uri.host == "packages.ecosyste.ms" && uri.port == 443 &&
        uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        uri.path.match?(%r{\A/api/v1/registries/[^/]+/packages/[^/]+/versions\z})
      raise RequestError, "invalid Packages versions URL"
    end

    response = client.connection.get(uri.path.delete_prefix("/api/v1/"), {
      per_page: PER_PAGE, page: state.fetch("page"), sort: "created_at", order: "asc",
      updated_after: state["updated_after"]
    }.compact)
    unless response.success?
      raise RequestError.new("versions request returned HTTP #{response.status}",
        retry_at: retry_after(response.headers["retry-after"]))
    end
    response
  rescue URI::InvalidURIError
    raise RequestError, "invalid Packages versions URL"
  end

  def next_page(response, records)
    link = response.headers["link"]
    if link.present?
      following = link.split(",").find { |entry| entry.match?(/;\s*rel=["']?next["']?(?:\s|;|$)/) }
      return unless following

      url = following[/<([^>]+)>/, 1]
      raise RequestError, "invalid next link for versions" unless url

      page = URI.decode_www_form(URI.parse(url).query.to_s).to_h["page"].to_i
      raise RequestError, "invalid next page for versions" unless page == state.fetch("page") + 1

      page
    elsif records.length >= PER_PAGE
      state.fetch("page") + 1
    end
  rescue URI::InvalidURIError => error
    raise RequestError, "invalid next link for versions: #{error.message}"
  end

  def retry_after(value)
    return 1.hour.from_now if value.blank?
    return [value.to_i.seconds.from_now, 1.minute.from_now].max if value.match?(/\A\d+\z/)

    [Time.httpdate(value), 1.minute.from_now].max
  rescue ArgumentError
    1.hour.from_now
  end

  def current_claim?
    package.version_sync_state["token"] == token &&
      state.slice(*source_identity.keys) == source_identity &&
      Package.version_importable.exists?(package.id)
  end

  def store_state!
    package.update_columns(version_sync_state: state)
  end

  def record_error!(error)
    return unless token

    retry_at = error.respond_to?(:retry_at) && error.retry_at || 1.hour.from_now
    package.with_lock do
      return unless current_claim?

      @state = state.except("token", "started_at").merge(
        "error" => "#{error.class}: #{error.message}".truncate(1_000), "retry_at" => retry_at.iso8601
      )
      store_state!
    end
    Rails.logger.warn("Version sync failed for package #{package.id}: #{state['error']}")
    SyncPackageVersionsWorker.perform_at(retry_at, package.id)
  end
end
