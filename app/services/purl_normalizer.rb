class PurlNormalizer
  # Julia's uuid qualifier is required by the PURL spec but General registry names are unique,
  # so packages match with or without it
  IGNORED_QUALIFIERS = { "julia" => %w[uuid] }.freeze

  def self.normalize(value)
    parsed = value.is_a?(Purl::PackageURL) ? value : Purl.parse(value)
    qualifiers = parsed.qualifiers&.except(*IGNORED_QUALIFIERS.fetch(parsed.type, []))
    parsed.with(version: nil, subpath: nil, qualifiers: qualifiers.presence).to_s
  end
end
