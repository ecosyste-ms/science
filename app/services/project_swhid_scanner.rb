require "tmpdir"

class ProjectSwhidScanner
  def initialize(project)
    @project = project
    @calculator = SwhidCalculator.new
  end

  def scan
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    origin = @project.repository&.dig("clone_url").presence || @project.url
    result = { "origin" => origin, "attempted_at" => Time.now.utc.iso8601 }

    Dir.mktmpdir("science-swhid-") do |directory|
      checkout = File.join(directory, "repository")
      result["clone_command"] = ["git", "clone", "--depth", "1", "--no-tags", "--", origin, checkout]
      @calculator.run(result["clone_command"])
      commit = @calculator.run(["git", "-C", checkout, "rev-parse", "HEAD"]).strip
      result["commit"] = commit
      result["revision"] = @calculator.calculate(type: "revision", path: checkout, ref: commit, origin: origin)
      result["directory"] = @calculator.calculate(type: "directory", path: checkout, origin: origin)
      result["metadata"] = metadata_evidence(checkout, commit, origin)
      result["status"] = %w[revision directory].all? { |type| result[type]["status"] == "success" } ? "success" : "error"
    end
    result
  rescue SwhidCalculator::CommandError, SystemCallError => error
    result.merge!("status" => "error", "error" => error.message.to_s.scrub[0, SwhidCalculator::ERROR_LIMIT])
  ensure
    result["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round if result
  end

  def metadata_evidence(checkout, commit, origin)
    {
      "citation_file" => @project.citation_file_name.presence || "CITATION.cff",
      "codemeta" => @project.codemeta_file_name.presence || "codemeta.json",
      "zenodo" => @project.zenodo_file_name.presence || ".zenodo.json"
    }.filter_map do |source, path|
      entry = @calculator.run(["git", "-C", checkout, "ls-tree", "-z", commit, "--", path])
      match = entry.match(/\A100(?:644|755) blob ([0-9a-f]{40})\t([^\x00]+)\x00\z/)
      next unless match && match[2] == path

      content = @calculator.run(["git", "-C", checkout, "cat-file", "blob", match[1]])
      [source, {
        "origin" => origin, "path" => path, "content_digest" => Digest::SHA256.hexdigest(content),
        "content_swhid" => "swh:1:cnt:#{match[1]}", "revision_swhid" => "swh:1:rev:#{commit}",
        "verified_at" => Time.current.iso8601
      }]
    rescue SwhidCalculator::CommandError
      nil
    end.to_h
  end
end
