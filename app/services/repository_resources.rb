require "digest"

class RepositoryResources
  def self.safe_path?(path)
    path.is_a?(String) && path.present? && !path.include?("\0") && !path.include?("\\") &&
      path.split("/", -1).none? { |part| part.empty? || %w[. .. .git].include?(part.downcase) }
  end

  def self.paths(brief)
    (brief["resources"] || {}).values_at("readme", "citation", "codemeta", "zenodo", "bibtex", "readme_bibtex")
      .map { |resource| resource.is_a?(Hash) ? resource["path"] : resource }.compact.uniq.sort
  end

  def self.read(checkout, path, url:)
    result = { "path" => path, "retrieved_at" => Time.current.iso8601, "url" => url }
    raise ArgumentError, "Invalid resource path" unless safe_path?(path)

    filename = File.join(checkout, path)
    unless File.realpath(filename).start_with?(File.realpath(checkout) + "/") && File.file?(filename)
      raise ArgumentError, "Resource must be a file inside the checkout"
    end
    content = File.binread(filename, 1.megabyte + 1).force_encoding(Encoding::UTF_8)
    raise ArgumentError, "Resource exceeds 1 MB" if content.bytesize > 1.megabyte
    raise ArgumentError, "Expected UTF-8 text" unless content.valid_encoding? && !content.include?("\0")
    raise ArgumentError, "Resource is an LFS pointer" if content.start_with?("version https://git-lfs.github.com/spec/v1\n")

    result.merge("status" => "ok", "content" => content, "bytes" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content))
  rescue ArgumentError, SystemCallError => error
    result.merge("status" => "error", "error" => error.message.to_s.scrub[0, 500])
  end
end
