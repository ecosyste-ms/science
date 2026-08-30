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
end
