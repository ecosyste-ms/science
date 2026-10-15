require "digest"

class CranCitationCollector
  def self.collect(purls)
    unless purls.is_a?(Array) && purls.length.between?(1, 25) &&
        purls.all? { |purl| purl.is_a?(String) && purl.length.between?(1, 2_000) }
      raise ArgumentError, "Expected 1 to 25 versioned CRAN PURLs"
    end
    collectors = purls.uniq.map do |purl|
      version = PackageVersion.includes(package: :package_registry).find_by(purl: purl)
      raise ArgumentError, "Import the package version first: #{purl}" unless version

      new(version)
    end
    results = collectors.map(&:call)
    { "versions" => results, "counts" => results.group_by { |result| result.fetch("status") }.transform_values(&:length) }
  end

  def initialize(version)
    @version = version
    @package = version.package
    parsed = Purl.parse(version.purl)
    unless parsed.type == "cran" && parsed.namespace.nil? && parsed.qualifiers.blank? && parsed.subpath.blank? &&
        parsed.name.match?(/\A[A-Za-z][A-Za-z0-9.]*\z/) && parsed.version == version.number &&
        parsed.with(version: nil).to_s == @package.purl && @package.package_registry.name.casecmp?("cran.r-project.org")
      raise ArgumentError, "Expected a versioned CRAN package"
    end
    @name = parsed.name
  rescue Purl::Error => error
    raise ArgumentError, error.message
  end

  def call
    result = { "package_id" => @package.id, "package_version_id" => @version.id,
      "purl" => @version.purl, "revision" => @version.number, "files" => [], "brief" => { "resources" => {} } }
    base = "https://cran.r-project.org/web/packages/#{@name}"
    description = fetch("#{base}/DESCRIPTION")
    published = description[/^Version:[\t ]*([^\r\n]+)/, 1]&.strip
    unless description[/^Package:[\t ]*([^\r\n]+)/, 1]&.strip == @name && published.present?
      raise ArgumentError, "CRAN DESCRIPTION does not identify the requested package"
    end
    result["published_version"] = published
    if published != @version.number
      return result.merge("status" => "version_mismatch", "error" => "CRAN citation pages describe the current release")
    end

    url = "#{base}/citation.html"
    content = fetch(url)
    unless Nokogiri::HTML(content).css("pre").any? { |node| node.text.match?(/^[\t ]*@\w+\s*\{/) }
      raise ArgumentError, "CRAN citation page has no BibTeX entries"
    end
    raise ArgumentError, "CRAN DESCRIPTION changed during collection" unless fetch("#{base}/DESCRIPTION") == description

    retrieved_at = Time.current.iso8601
    result.merge("status" => "complete",
      "file_list_source" => { "source" => "cran", "url" => "#{base}/DESCRIPTION", "revision" => published,
        "sha256" => Digest::SHA256.hexdigest(description), "retrieved_at" => retrieved_at },
      "files" => [{ "path" => "citation.html", "url" => url, "content" => content, "status" => "ok",
        "bytes" => content.bytesize, "sha256" => Digest::SHA256.hexdigest(content), "retrieved_at" => retrieved_at }])
  rescue ArgumentError, Faraday::Error => error
    result.merge("status" => "error", "error" => error.message.to_s.scrub[0, 500])
  end

  def fetch(url)
    response = Faraday.get(url, nil, { "User-Agent" => "science.ecosyste.ms", "Accept" => "text/html, text/plain" }) do |request|
      request.options.open_timeout = 5
      request.options.timeout = 20
    end
    raise ArgumentError, "CRAN HTTP #{response.status}" unless response.success?
    content = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, "CRAN response exceeds 1 MB" if content.bytesize > 1.megabyte
    raise ArgumentError, "Expected UTF-8 text from CRAN" unless content.valid_encoding? && !content.include?("\0")

    content
  end
end
