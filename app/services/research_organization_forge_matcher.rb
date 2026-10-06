require "uri"

class ResearchOrganizationForgeMatcher
  def self.call(owner)
    base = host_uri(owner.host)
    return [] unless base

    path = "#{base.path.chomp('/')}/#{owner.login}".downcase
    paths = [path]
    if owner.host.kind.to_s.casecmp?("gitlab") || owner.host.name.casecmp?("GitLab")
      paths << "#{base.path.chomp('/')}/groups/#{owner.login}".downcase
    end
    hostname = base.host.downcase.sub(/\Awww\./, "")
    pattern = "%#{ResearchOrganization.sanitize_sql_like(hostname)}%"
    ResearchOrganization.active.where("(metadata -> 'links')::text ILIKE ?", pattern).filter_map do |organization|
      urls = organization.metadata.fetch("links", []).filter_map do |link|
        next unless link["type"] == "website"
        uri = parse_url(link["value"])
        next unless uri && uri.host.downcase.sub(/\Awww\./, "") == hostname && port(uri) == port(base)
        next unless paths.include?(URI::DEFAULT_PARSER.unescape(uri.path).chomp('/').downcase)

        link["value"]
      end
      next if urls.empty?

      { organization: organization, match_method: "ror_forge_url",
        evidence: { "host" => hostname, "owner_login" => owner.login, "matched_urls" => urls.uniq } }
    end
  end

  def self.host_uri(host)
    return unless host

    value = host.url.presence
    if value.nil?
      value = case host.name.downcase
      when "github" then "https://github.com"
      when "gitlab" then "https://gitlab.com"
      else "https://#{host.name}" if PublicSuffix.valid?(host.name)
      end
    end
    uri = parse_url(value)
    uri if uri && uri.query.nil? && uri.fragment.nil?
  end

  def self.parse_url(value)
    uri = URI.parse(value.to_s.strip)
    uri if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end

  def self.port(uri)
    uri.port unless uri.port == uri.default_port
  end
end
