class SoftwareSearch
  KINDS = %w[name doi repository_url homepage_url purl].freeze

  def self.results(query:, kind: "name", limit: 10, after_id: 0, search: false)
    raise ArgumentError, "kind must be one of: #{KINDS.join(', ')}" unless KINDS.include?(kind)
    unless query.is_a?(String) && query.strip.length.between?(1, 2000)
      raise ArgumentError, "query must contain 1 to 2000 characters"
    end
    limit = Integer(limit.to_s, 10, exception: false)
    after_id = Integer(after_id.to_s, 10, exception: false)
    raise ArgumentError, "limit must be between 1 and 25" unless limit&.between?(1, 25)
    unless after_id&.between?(0, 9_223_372_036_854_775_807)
      raise ArgumentError, "after_id must be a nonnegative integer"
    end

    value = normalize(query, kind)
    scope = ProjectSearchSeeds.scope.select(:search_indexed_at).where("projects.id > ?", after_id)
    if search
      raise ArgumentError, "search requires at least 3 characters" if value.length < 3

      scope = scope.where("search_names LIKE ?", "%#{Project.sanitize_sql_like(value)}%")
    else
      scope = scope.where("search_identifiers @> ?::jsonb", { kind => [value] }.to_json)
    end
    projects = scope.limit(limit + 1).to_a
    {
      query: value, kind: kind, match: search ? "contains" : "exact",
      next_after_id: projects.length > limit ? projects[limit - 1].id : nil,
      projects: projects.first(limit).filter_map { |project| evidence(project, value, kind, search) },
    }
  end

  def self.normalize(query, kind)
    value = query.strip
    return value.unicode_normalize(:nfc).downcase if kind == "name"
    return value.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}i, "").downcase if kind == "doi"
    return Purl.parse(value).with(version: nil, subpath: nil).to_s if kind == "purl"

    uri = URI.parse(value)
    unless %w[http https].include?(uri.scheme&.downcase) && uri.host.present? && uri.userinfo.nil?
      raise ArgumentError, "use a complete HTTP(S) URL without credentials"
    end
    uri.scheme = uri.scheme.downcase
    uri.host = uri.host.downcase
    uri.to_s
  rescue URI::InvalidURIError, Purl::Error
    raise ArgumentError, "invalid #{kind}"
  end

  def self.evidence(project, value, kind, search)
    document = ProjectSearchSeeds.new(project).as_json
    matches = ->(seed) do
      seed[:type] == kind && (search ? seed[:normalized_value].include?(value) : seed[:normalized_value] == value)
    end
    document[:seeds].select!(&matches)
    document[:packages] = document[:packages].filter_map do |package|
      package[:seeds].select!(&matches)
      package if package[:seeds].any? || (kind == "purl" && package[:purl] == value)
    end
    return if document[:seeds].empty? && document[:packages].empty?

    document.merge(indexed_at: project.search_indexed_at)
  end
end
