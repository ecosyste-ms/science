require "uri"

class RepositoryUrlNormalizer
  GITLAB_PATH_MARKERS = %w[
    -
    activity
    blob
    commits
    issues
    merge_requests
    raw
    releases
    tree
    wikis
  ].freeze

  def self.normalize(value)
    uri = parse(value)
    return unless uri
    pages_repository = github_pages_repository(value)
    return pages_repository if pages_repository

    host = uri.host.to_s.downcase.delete_prefix("www.")
    segments = uri.path.split("/").reject(&:blank?)
    return if segments.length < 2

    if host == "github.com" || host == "bitbucket.org"
      segments = segments.first(2)
    else
      marker = segments.each_index.find do |index|
        index >= 2 && GITLAB_PATH_MARKERS.include?(segments[index].downcase)
      end
      segments = segments.first(marker) if marker
    end

    segments[-1] = segments[-1].delete_suffix(".git")
    return if segments.any? { |segment| segment.blank? }

    "https://#{host}/#{segments.join('/')}".downcase
  end

  def self.parse(value)
    string = value.to_s.strip
    return if string.blank?

    if (match = string.match(/\Agithub:([a-z0-9-]+\/[a-z0-9_.-]+)\z/i))
      string = "https://github.com/#{match[1]}"
    end

    if (match = string.match(/\Agit@([^:]+):(.+)\z/i))
      return URI.parse("ssh://git@#{match[1]}/#{match[2]}")
    end

    string = string.delete_prefix("git+")
    uri = URI.parse(string)
    return unless %w[http https git ssh].include?(uri.scheme&.downcase)
    return if uri.host.blank?

    uri
  rescue URI::InvalidURIError
    nil
  end

  def self.github_pages_repository(value)
    uri = parse(value)
    return unless uri && %w[http https].include?(uri.scheme) && uri.userinfo.nil? && [80, 443].include?(uri.port)
    match = uri.host.downcase.match(/\A([a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?)\.github\.io\z/)
    return unless match
    repository = uri.path.split("/").reject(&:blank?).first
    return unless repository&.match?(/\A[a-z0-9_.-]+\z/i)
    return if %w[. ..].include?(repository) || repository.match?(/\.(?:html?|pdf)\z/i)
    "https://github.com/#{match[1]}/#{repository}".downcase
  end
end
