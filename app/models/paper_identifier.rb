class PaperIdentifier < ApplicationRecord
  belongs_to :paper

  validates :source, :identifier, presence: true
  validates :identifier, uniqueness: { scope: :source }

  def self.from_urls(urls)
    Array(urls).filter_map do |url|
      uri = URI.parse(url.to_s)
      next unless %w[http https].include?(uri.scheme)
      next unless uri.userinfo.nil? && [80, 443].include?(uri.port)
      if uri.host&.downcase == JorsClient::HOST
        match = uri.path.match(%r{\A/(?:en/)?articles/(10\.5334/jors\.[a-z0-9]+)/?\z}i)
        next({ source: "jors", identifier: match[1].downcase }) if match
      end
      next unless %w[jmlr.org www.jmlr.org].include?(uri.host&.downcase)
      match = uri.path.match(%r{\A/papers/v([1-9][0-9]*)/([a-zA-Z0-9_-]+)\.html\z}) ||
        uri.path.match(%r{\A/papers/(?:volume|v)([1-9][0-9]*)/([a-zA-Z0-9_-]+)/\2\.pdf\z})
      { source: "jmlr", identifier: "v#{match[1]}/#{match[2]}" } if match
    rescue URI::InvalidURIError
      nil
    end.uniq
  end

  def self.urls_for(identity)
    if identity.fetch(:source) == "jors"
      return %w[https http].product(["articles", "en/articles"]).map { |scheme, path| "#{scheme}://#{JorsClient::HOST}/#{path}/#{identity.fetch(:identifier)}" }
    end
    return [] unless identity.fetch(:source) == "jmlr"
    volume, article = identity.fetch(:identifier).split("/", 2)
    paths = ["/papers/#{volume}/#{article}.html", "/papers/#{volume}/#{article}/#{article}.pdf",
      "/papers/volume#{volume.delete_prefix('v')}/#{article}/#{article}.pdf"]
    %w[https http].product(%w[www.jmlr.org jmlr.org], paths).map { |scheme, host, path| "#{scheme}://#{host}#{path}" }
  end

  def self.paper_ids_for(identities)
    identities.flat_map do |identity|
      where(identity).pluck(:paper_id) + Paper.where("urls && ARRAY[?]::text[]", urls_for(identity)).limit(2).pluck(:id)
    end.uniq
  end

  def self.lock_keys(identities)
    identities.map { |identity| "#{identity.fetch(:source)}:#{identity.fetch(:identifier)}" }
  end

  def self.attach!(paper, identities)
    identities.each do |identity|
      if paper.paper_identifiers.where(source: identity.fetch(:source)).where.not(identifier: identity.fetch(:identifier)).exists?
        raise ArgumentError, "Conflicting publisher article identifiers"
      end
      paper.paper_identifiers.find_or_create_by!(identity)
    end
  end
end
