require "digest"

class HuggingFaceIntrinsicFiles
  FILE_NAMES = %w[readme.md citation.cff citation.bib citation citation.md codemeta.json config.json].freeze
  MAX_VERSIONS = 25

  attr_reader :version, :package, :revision, :model_path, :client

  def self.collect(purls)
    unless purls.is_a?(Array) && purls.length.between?(1, MAX_VERSIONS) &&
        purls.all? { |purl| purl.is_a?(String) && purl.length.between?(1, 2_000) }
      raise ArgumentError, "Expected 1 to #{MAX_VERSIONS} versioned Hugging Face PURLs"
    end
    collectors = purls.uniq.map do |purl|
      version = PackageVersion.includes(package: :package_registry).find_by(purl: purl)
      raise ArgumentError, "Import the package version first: #{purl}" unless version

      new(version)
    end
    results = collectors.map(&:call)
    { "versions" => results, "counts" => results.group_by { |result| result.fetch("status") }.transform_values(&:length) }
  end

  def initialize(version, client: HuggingFaceFileClient.new)
    @version = version
    @package = version.package
    @client = client
    parsed = Purl.parse(version.purl)
    @revision = parsed.version
    unless parsed.type == "huggingface" && parsed.namespace.present? &&
        [parsed.namespace, parsed.name].all? { |part| part.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) } &&
        parsed.qualifiers.blank? && parsed.subpath.blank? && revision.to_s.match?(/\A[0-9a-f]{40}\z/) &&
        revision == version.number && parsed.with(version: nil).to_s == package.purl &&
        package.package_registry.name.casecmp?("huggingface.co")
      raise ArgumentError, "Expected a Hugging Face package version pinned to a commit SHA"
    end
    @model_path = "#{parsed.namespace}/#{parsed.name}"
  rescue Purl::Error => error
    raise ArgumentError, error.message
  end

  def call
    result = { "package_id" => package.id, "package_version_id" => version.id,
      "purl" => version.purl, "revision" => revision, "files" => [] }
    paths, source = file_list
    result["file_list_source"] = source
    selected = paths.select { |path| FILE_NAMES.include?(path.downcase) }.uniq.sort
    if selected.length > FILE_NAMES.length
      raise HuggingFaceFileClient::RequestError, "Too many intrinsic files"
    end
    result["files"] = selected.map { |path| fetch_file(path) }
    result["status"] = if selected.empty?
      "no_files"
    elsif result["files"].all? { |file| file["status"] == "ok" }
      "complete"
    else
      "partial"
    end
    result
  rescue HuggingFaceFileClient::RequestError => error
    result.merge("status" => "error", "error" => error.message)
  end

  def file_list
    paths = package.metadata.dig("metadata", "files")
    if package.metadata["latest_release_number"] == revision && paths.is_a?(Array) && paths.all?(String)
      return [paths, { "source" => "packages", "ecosystems_id" => package.ecosystems_id,
        "retrieved_at" => package.ecosystems_checked_at&.iso8601 }]
    end

    url = "https://huggingface.co/api/models/#{model_path}/revision/#{revision}"
    response = client.get(url, limit: 2.megabytes)
    unless response["status"] == 200
      raise HuggingFaceFileClient::RequestError, "Hub file list returned HTTP #{response['status']}"
    end
    model = JSON.parse(response.fetch("body"))
    unless model.is_a?(Hash) && model["sha"] == revision && model["siblings"].is_a?(Array)
      raise HuggingFaceFileClient::RequestError, "Hub file list does not describe the selected revision"
    end
    paths = model["siblings"].map { |file| file.is_a?(Hash) && file["rfilename"] }
    unless paths.all?(String)
      raise HuggingFaceFileClient::RequestError, "Invalid Hub file list"
    end
    [paths, { "source" => "huggingface", "url" => url, "retrieved_at" => Time.current.iso8601 }]
  rescue JSON::ParserError
    raise HuggingFaceFileClient::RequestError, "Invalid Hub metadata JSON"
  end

  def fetch_file(path)
    url = "https://huggingface.co/#{model_path}/resolve/#{revision}/#{path}"
    result = { "path" => path, "url" => url, "retrieved_at" => Time.current.iso8601 }
    response = client.get(url, limit: 1.megabyte)
    result.merge!(response.except("body", "status"))
    result["http_status"] = response["status"]
    result["status"] = case response["status"]
    when 200 then "ok"
    when 401, 403 then "gated"
    when 404 then "missing"
    when 429 then "rate_limited"
    else "error"
    end
    return result unless result["status"] == "ok"

    body = response.fetch("body").dup.force_encoding(Encoding::UTF_8)
    unless body.valid_encoding? && !body.include?("\0")
      raise HuggingFaceFileClient::RequestError, "Expected UTF-8 text"
    end
    result.merge("content" => body, "bytes" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body))
  rescue HuggingFaceFileClient::RequestError => error
    result.merge("status" => "error", "error" => error.message)
  end
end
