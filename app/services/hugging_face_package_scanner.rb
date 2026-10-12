class HuggingFacePackageScanner
  MAX_VERSIONS = 25

  attr_reader :version, :package, :revision, :model_path

  def self.collect(purls)
    unless purls.is_a?(Array) && purls.length.between?(1, MAX_VERSIONS) &&
        purls.all? { |purl| purl.is_a?(String) && purl.length.between?(1, 2_000) }
      raise ArgumentError, "Expected 1 to #{MAX_VERSIONS} versioned Hugging Face PURLs"
    end
    scanners = purls.uniq.map do |purl|
      version = PackageVersion.includes(package: :package_registry).find_by(purl: purl)
      raise ArgumentError, "Import the package version first: #{purl}" unless version

      new(version)
    end
    results = scanners.map(&:call)
    { "versions" => results, "counts" => results.group_by { |result| result.fetch("status") }.transform_values(&:length) }
  end

  def initialize(version)
    @version = version
    @package = version.package
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
    origin = "https://huggingface.co/#{model_path}"
    project = ModelProjectSync.link!(package)
    result["project_id"] = project.id
    scanner = ProjectRepositoryScanner.new(project, force_brief: true, revision: revision)
    scanner.scan
    brief = project.reload.brief
    if brief.nil? || brief["error"]
      return result.merge("status" => "error", "error" => brief&.dig("error") || "Project scan did not complete")
    end
    result.merge("brief" => brief, "file_list_source" => { "source" => "git", "url" => origin, "revision" => revision },
      "files" => scanner.files, "status" => scanner.files.all? { |file| file["status"] == "ok" } ? "complete" : "partial")
  rescue ArgumentError => error
    result.merge("status" => "error", "error" => error.message.to_s.scrub[0, 500])
  end
end
