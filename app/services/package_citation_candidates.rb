require "tmpdir"
require "digest"
require "fileutils"

class PackageCitationCandidates
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
    unless row.is_a?(Hash) && row["purl"].is_a?(String) && row["files"].is_a?(Array) && row["files"].length <= 7
      raise ArgumentError, "Invalid package file collection"
    end
    version = PackageVersion.includes(:package).find_by(purl: row["purl"])
    unless version && row["package_version_id"] == version.id && row["package_id"] == version.package_id && row["revision"] == version.number
      raise ArgumentError, "Collection must identify an existing package version"
    end
    if row.key?("brief") && (!row["brief"].is_a?(Hash) || (row["brief"]["resources"] && !row["brief"]["resources"].is_a?(Hash)))
      raise ArgumentError, "Expected Brief resources in the collection report"
    end
    paths = []
    row["files"].each do |file|
      unless file.is_a?(Hash) && RepositoryResources.safe_path?(file["path"]) && !paths.include?(file["path"])
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
      brief = row["brief"] || begin
        files.each do |file|
          path = File.join(directory, file.fetch("path"))
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, file.fetch("content"))
        end
        RepositoryBriefScan.call(directory)
      end
      result["brief"] = brief.slice("version", "resources")
      resources = brief["resources"] || {}
      result["diagnostics"] = []
      files.reject { |file| File.basename(file["path"]).casecmp?("config.json") }.each do |file|
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
            "file_retrieved_at" => file["retrieved_at"], "file_list_source" => row["file_list_source"])
        end)
        result["diagnostics"].concat(extractor.diagnostics.map { |item| { "path" => file["path"], "parser" => "bibtex-ruby", "diagnostic" => item } })
      end
    end
    result
  rescue RepositoryCommand::Error, SystemCallError, JSON::ParserError => error
    result.merge("extraction_error" => error.message)
  end
end
