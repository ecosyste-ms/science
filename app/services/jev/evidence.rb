class Jev::Evidence
  include EcosystemApiClient
  REPOSITORY_FIELDS = %w[full_name description language topics fork archived pushed_at default_branch latest_commit_sha size metadata html_url previous_names source_name mirror_url].freeze
  SOURCE_EXTENSION = /\.(?:r|jl|py|pyx|pxd|cpp|c|h|cc|cxx|hpp|cu|cuh|ts|js|ipynb|sh|f|f90|f95|f03|f08|go|rs|java|scala|rb|m|rmd|qmd|nf|smk|swift|vb|vba|pro|wl|wls|nb|cs|fs|fsx|hs|lua|pl|pm|php|sas)\z/i

  def self.repository_url(value)
    uri = RepositoryUrlNormalizer.parse(value)
    return unless uri && uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? &&
      %w[github.com gitlab.com codeberg.org].include?(uri.host.downcase)
    normalized = RepositoryUrlNormalizer.normalize(value)
    return unless normalized && URI(normalized).path.split('/').reject(&:empty?).all? { |part| part.match?(/\A[a-z0-9_.-]+\z/i) && !%w[. ..].include?(part) }
    normalized
  end

  def self.metadata(project: nil, repository: nil, package: nil, url: nil)
    repo = repository || project&.repository || {}
    data = { "name" => project&.name || repo["full_name"] || url.to_s.split('/').last,
      "description" => project&.description.presence || repo["description"] || package&.metadata&.[]("description"),
      "repository" => url || project&.url,
      "topics" => (Array(project&.keywords) + Array(repo["topics"])).grep(String).map { |topic| topic.strip[0, 80] }.uniq.sort.first(40),
      "language" => project&.language || repo["language"],
      "packages" => Array(project&.packages).grep(Hash).first(8).map { |p| p.slice("name", "description", "ecosystem") },
      "package_descriptions" => Array(repo.dig("metadata", "r_package_descriptions")).grep(Hash).first(3).map { |p| (p["fields"] || {}).slice("Package", "Title", "Description") } }
    data["packages"] << { "name" => package.name, "description" => package.metadata["description"], "ecosystem" => package.package_registry.ecosystem } if package
    data.transform_values! { |value| clean(value) }
    data.reject { |_, value| value.nil? || value == [] }
  end

  def self.clean(value)
    case value
    when String then value.scrub.delete("\0")[0, 1000]
    when Hash then value.transform_values { |item| clean(item) }
    when Array then value.map { |item| clean(item) }
    else value
    end
  end

  def self.get(url, params = {})
    response = ecosystem_http_get(params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}")
    raise Jev::Client::Unavailable, "Repository metadata HTTP #{response.status}" unless response.success?
    JSON.parse(response.body)
  rescue JSON::ParserError, Faraday::Error => error
    raise Jev::Client::Unavailable, "Repository metadata failed: #{error.class}"
  end

  def self.fingerprint(metadata, project: nil, repository: nil)
    repo = repository || project&.repository || {}
    Jev::Client.fingerprint([metadata, repo.slice("pushed_at", "latest_commit_sha", "default_branch"),
      project && Digest::SHA256.hexdigest(project.readme.to_s), project&.brief&.slice("languages", "lines")])
  end

  def self.repository_endpoint(url)
    uri = URI(url)
    host = { "github.com" => "GitHub", "gitlab.com" => "GitLab", "codeberg.org" => "Codeberg" }.fetch(uri.host)
    "https://repos.ecosyste.ms/api/v1/hosts/#{host}/repositories/#{ERB::Util.url_encode(uri.path.delete_prefix('/'))}"
  end

  def collect(discovery)
    evidence = discovery.evidence.deep_dup
    project = discovery.project
    metadata = evidence.fetch("metadata")
    state = metadata.deep_dup
    state["readme"] = project.readme.to_s[0, 8000] if project&.readme.present?
    if project&.brief.is_a?(Hash)
      state["brief"] = structural_brief(project.brief)
    end
    errors = []
    collection_started = nil
    Jev::Limiter.with_slot("enrich") do
      collection_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      disk_limit = Jev::Settings.integer("DISK_LIMIT_MB", 200, 25..500).megabytes
      checkout = RepositoryCheckout.new(discovery.repository_url, skip_lfs: true, disk_limit: disk_limit, partial: true)
      checkout.open do |path, _, _|
        command = RepositoryCommand.new(timeout: 60, output_limit: 4.megabytes)
        revision = command.run(["git", "-C", path, "rev-parse", "HEAD"]).strip
        files = command.run(["git", "-C", path, "ls-files", "-z"]).dup.force_encoding("UTF-8").scrub.split("\0")
        sources = files.select { |file| file.match?(SOURCE_EXTENSION) || %w[Snakefile Makefile].include?(File.basename(file)) }
        state["source_file_paths"] = sources.first(80)
        state["source_paths_truncated"] = sources.size > 80
        begin
          brief = RepositoryBriefScan.call(path)
          state["brief"] = structural_brief(brief)
          errors << "Brief line counts unavailable" if state["brief"]["lines"].blank?
          evidence["brief_version"] = brief["version"]
        rescue RepositoryCommand::Error, JSON::ParserError => error
          errors << "Brief scan failed: #{error.class}"
        end
        readme = files.select { |file| File.basename(file).match?(/\Areadme(?:\.(?:md|markdown|rst|txt|rmd|adoc))?\z/i) && file.count('/') <= 1 }
          .min_by { |file| [file.count('/'), file.downcase, file] }
        if readme
          filename = File.realpath(File.join(path, readme)) rescue nil
          if filename&.start_with?(File.realpath(path) + File::SEPARATOR) && File.file?(filename)
            state["readme"] = File.binread(filename, 40_000).to_s.dup.force_encoding("UTF-8").scrub.delete("\0")[0, 8000]
            evidence["readme_path"] = readme
          end
        end
        evidence["revision"] = revision
        evidence["skipped_large_files"] = checkout.skipped_paths
        evidence["source_paths_complete"] = checkout.skipped_paths.zero?
      end
      evidence["collection_ms"] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - collection_started) * 1000
    end
    evidence["enriched"] = state
    evidence["collected_at"] = Time.current.iso8601
    [evidence, errors.presence&.join("; ")]
  rescue RepositoryCommand::Error, Errno::ENOENT => error
    evidence["checkout_error"] = checkout_error_kind(error)
    evidence["collection_ms"] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - collection_started) * 1000 if collection_started
    evidence["enriched"] = state
    evidence["source_paths_complete"] = false
    evidence["collected_at"] = Time.current.iso8601
    [evidence, "Repository checkout failed: #{evidence['checkout_error']}"]
  end

  def checkout_error_kind(error)
    case error.message
    when /repository disk limit exceeded/i then "disk_limit"
    when /command timed out/i then "timeout"
    when /rate limit|returned error: 429/i then "rate_limited"
    when /repository not found|authentication failed|could not read Username|returned error: (?:401|403|404)/i then "unavailable"
    when /unknown revision|ambiguous argument.*HEAD|remote HEAD.*nonexistent/i then "missing_revision"
    when /command output exceeds/i then "output_limit"
    else "command_failed"
    end
  end

  def structural_brief(brief)
    { "languages" => Array(brief["languages"]).filter_map { |item| item.is_a?(Hash) ? item["name"] : item },
      "lines" => brief["lines"] }.compact
  end
end
