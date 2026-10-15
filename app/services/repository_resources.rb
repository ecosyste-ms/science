require "digest"

class RepositoryResources
  def self.store(project, files, revision:)
    paths = resource_paths(project.brief)
    by_path = files.index_by { |file| file["path"] }
    attributes = {}
    repository = project.repository.deep_dup
    metadata = repository["metadata"] ||= {}
    stored_paths = metadata.fetch("files", {}).dup
    sources = metadata.fetch("file_sources", {}).dup
    { "readme" => :readme, "citation" => :citation_file, "codemeta" => :codemeta, "zenodo" => :zenodo }.each do |key, attribute|
      file = by_path[paths[key]]
      next if paths[key] && file&.dig("status") != "ok"

      attributes[attribute] = file&.fetch("content", nil)
      stored_paths[key] = paths[key]
      sources[key] = file&.except("content")&.merge("revision" => revision)
    end
    metadata["files"] = stored_paths.compact
    metadata["file_sources"] = sources.compact
    if project.repository_from_package? && project.swhids && project.swhids["commit"] != revision
      attributes[:swhids] = project.swhids.slice("origin_archive")
    end
    attributes[:last_synced_at] = Time.current if project.repository_from_package?
    project.update!(**attributes, repository: repository,
      brief: project.brief.merge("revision" => revision, "scanned_at" => Time.current.iso8601,
        "collected_files" => files.map { |file| file.except("content") }))
  end

  def self.safe_path?(path)
    path.is_a?(String) && path.present? && !path.include?("\0") && !path.include?("\\") &&
      path.split("/", -1).none? { |part| part.empty? || %w[. .. .git].include?(part.downcase) }
  end

  def self.paths(brief)
    resource_paths(brief).values.uniq.sort
  end

  def self.resource_paths(brief)
    resources = brief["resources"] || {}
    metadata = resources["metadata"] || {}
    %w[readme citation codemeta zenodo bibtex readme_bibtex].filter_map do |key|
      resource = metadata[key] || resources[key]
      resource ||= resources["bibtex"] if key == "citation"
      path = resource.is_a?(Hash) ? resource["path"] : resource
      [key, path] if path.is_a?(String) && path.present?
    end.to_h
  end

  def self.read(checkout, path, url:)
    result = { "path" => path, "retrieved_at" => Time.current.iso8601, "url" => url }
    raise ArgumentError, "Invalid resource path" unless safe_path?(path)

    filename = File.join(checkout, path)
    unless File.realpath(filename).start_with?(File.realpath(checkout) + "/") && File.file?(filename)
      raise ArgumentError, "Resource must be a file inside the checkout"
    end
    content = (File.binread(filename, 1.megabyte + 1) || String.new).force_encoding(Encoding::UTF_8)
    raise ArgumentError, "Resource exceeds 1 MB" if content.bytesize > 1.megabyte
    raise ArgumentError, "Expected UTF-8 text" unless content.valid_encoding? && !content.include?("\0")
    raise ArgumentError, "Resource is an LFS pointer" if content.start_with?("version https://git-lfs.github.com/spec/v1\n")

    result.merge("status" => "ok", "content" => content, "bytes" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content))
  rescue ArgumentError, SystemCallError => error
    result.merge("status" => "error", "error" => error.message.to_s.scrub[0, 500])
  end
end
