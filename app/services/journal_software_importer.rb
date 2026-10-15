class JournalSoftwareImporter < ExternalSoftwareImporter
  def repository_statements(entity)
    Array(entity["code_urls"]).filter_map do |url|
      next unless url.is_a?(String) && url.length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(url)
      next unless uri && uri.userinfo.nil? && %w[http https].include?(uri.scheme) && [80, 443].include?(uri.port)
      next if uri.path.split("/").any? { |segment| %w[. ..].include?(segment) }
      next if RepositoryUrlNormalizer.github_pages_repository(url)
      normalized = RepositoryUrlNormalizer.normalize(url)
      next unless normalized && repository_url?(normalized)
      { repository_url: url, source_field: "code_urls", article_url: entity.fetch("article_url"),
        collection_url: self.class::CLIENT::CATALOGUE_URL }
    end.uniq
  end

  def persist_links(record, entity, matches)
    super
    JournalPublicationIndexer.new.sync!(record, entity)
  end
end
