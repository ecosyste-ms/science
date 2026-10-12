require "tmpdir"
require "digest"

class PackageCitationCandidates
  FILE_NAMES = %w[readme.md citation.cff citation.bib citation citation.md codemeta.json config.json].freeze

  def call(report)
    rows = report.is_a?(Hash) && report["versions"]
    unless rows.is_a?(Array) && rows.length.between?(1, 25)
      raise ArgumentError, "Expected a collection report with 1 to 25 package versions"
    end
    versions = rows.map { |row| validate(row) }
    results = rows.zip(versions).map { |row, version| extract(row, version) }
    candidates = results.flat_map { |result| result.fetch("candidates") }
    { "summary" => { "versions" => results.length, "candidates" => candidates.length,
        "extraction_errors" => results.count { |result| result["extraction_error"] },
        "identifier_kinds" => candidates.group_by { |candidate| candidate.fetch("identifier_kind") }.transform_values(&:length) },
      "versions" => results.map { |result| result.except("candidates") }, "candidates" => candidates }
  end

  def validate(row)
    unless row.is_a?(Hash) && row["purl"].is_a?(String) && row["files"].is_a?(Array) && row["files"].length <= FILE_NAMES.length
      raise ArgumentError, "Invalid package file collection"
    end
    version = PackageVersion.includes(:package).find_by(purl: row["purl"])
    unless version && row["package_version_id"] == version.id && row["package_id"] == version.package_id && row["revision"] == version.number
      raise ArgumentError, "Collection must identify an existing package version"
    end
    paths = []
    row["files"].each do |file|
      unless file.is_a?(Hash) && file["path"].is_a?(String) && FILE_NAMES.include?(file["path"].downcase) && !paths.include?(file["path"])
        raise ArgumentError, "Invalid or repeated collected file path"
      end
      paths << file["path"]
      next unless file["status"] == "ok"

      content = file["content"]
      unless content.is_a?(String) && content.bytesize <= 1.megabyte && content.bytesize == file["bytes"] &&
          Digest::SHA256.hexdigest(content) == file["sha256"] && file["url"].is_a?(String)
        raise ArgumentError, "Collected file content must match its size and checksum"
      end
    end
    version
  end

  def extract(row, version)
    result = row.except("files").merge("files" => row["files"].map { |file| file.except("content") }, "candidates" => [])
    files = row["files"].select { |file| file["status"] == "ok" }
    return result if files.empty?

    Dir.mktmpdir("science-package-citations-") do |directory|
      files.each { |file| File.write(File.join(directory, file.fetch("path")), file.fetch("content")) }
      output = RepositoryCommand.new(timeout: 60, output_limit: 10.megabytes).run(["brief", "-json", directory])
      brief = JSON.parse(output)
      result["brief"] = brief.slice("version", "resources")
      resources = brief.fetch("resources", {})
      result["diagnostics"] = []
      files.reject { |file| file["path"].casecmp?("config.json") }.each do |file|
        entries = %w[bibtex readme_bibtex].flat_map do |key|
          resource = resources[key]
          next [] unless resource.is_a?(Hash) && resource["path"] == file["path"]

          result["diagnostics"].concat(Array(resource["diagnostics"]).map { |item| { "path" => file["path"], "parser" => "brief", "diagnostic" => item } })
          Array(resource["entries"])
        end
        extractor = FilePaperCandidates.new(file)
        result["candidates"].concat(extractor.extract(brief_entries: entries).map do |candidate|
          candidate.merge("purl" => version.purl, "package_purl" => version.package.purl,
            "package_id" => version.package_id, "package_version_id" => version.id, "revision" => version.number,
            "file_path" => file["path"], "file_url" => file["url"], "file_sha256" => file["sha256"],
            "file_retrieved_at" => file["retrieved_at"])
        end)
        result["diagnostics"].concat(extractor.diagnostics.map { |item| { "path" => file["path"], "parser" => "bibtex-ruby", "diagnostic" => item } })
      end
    end
    result
  rescue RepositoryCommand::Error, SystemCallError, JSON::ParserError => error
    result.merge("extraction_error" => error.message)
  end
end
