require "digest"
require "set"

class PapersWithCodeImporter
  SOURCE = "papers_with_code"
  DATASET = "https://huggingface.co/datasets/pwc-archive/links-between-paper-and-code"
  LICENSE = "https://creativecommons.org/licenses/by-sa/4.0/"

  def call(file:, output:, snapshot:, sha256:, apply: false, limit: nil)
    raise ArgumentError, "Limit must be a positive integer" unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
    raise ArgumentError, "Apply must be true or false" unless apply == true || apply == false
    raise ArgumentError, "Expected an archive commit SHA" unless snapshot.to_s.match?(/\A[0-9a-f]{40}\z/)
    raise ArgumentError, "Archive SHA-256 does not match" unless sha256.to_s.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(file).hexdigest == sha256
    raise ArgumentError, "Input and output must be different files" if File.expand_path(file) == File.expand_path(output)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @snapshot, @sha256, @apply = snapshot, sha256, apply
    @seen = Set.new
    @planned_pairs = Set.new
    @planned_papers = Set.new
    @planned_projects = Set.new
    @discovery = ExternalRepositoryDiscovery.new
    counts = Hash.new(0)
    processed = 0
    summary = -> {
      { "counts" => counts.dup, "processed" => processed, "limit" => limit, "applied" => apply,
        "snapshot" => snapshot, "input_sha256" => sha256,
        "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    }
    File.open(output, "wx") do |ledger|
      @paper_index = paper_index
      input = File.foreach(file).lazy
      input = input.take(limit) if limit
      input.each_slice(100) do |lines|
        rows = lines.map { |line| JSON.parse(line) }
        lookups = repository_lookups(rows)
        rows.each do |row|
          result = process(row, lookups)
          counts[result.fetch("status")] += 1
          counts["new_papers"] += 1 if result["new_paper"]
          counts["new_projects"] += 1 if result["new_project"]
          counts["sync_requests"] += 1 if result["sync_requested"]
          processed += 1
          ledger.puts JSON.generate(result.merge("line" => processed, "record" => row, "snapshot" => snapshot, "input_sha256" => sha256,
            "source" => SOURCE, "archive_url" => "#{DATASET}/tree/#{snapshot}", "license" => LICENSE,
            "attribution" => "Papers with Code; archived by pwc-archive", "applied" => apply))
        end
        ledger.flush
        yield summary.call if block_given?
      end
    end
    summary.call
  end

  def repository_lookups(rows)
    urls = rows.filter_map do |row|
      next unless row.is_a?(Hash) && row["repo_url"].is_a?(String) && row["repo_url"].length.between?(1, 2000)
      uri = RepositoryUrlNormalizer.parse(row["repo_url"])
      row["repo_url"] if uri && uri.userinfo.nil? && RepositoryUrlNormalizer.normalize(row["repo_url"])
    end.uniq
    urls.empty? ? {} : ProjectRepositoryLookup.call(urls).index_by { |entry| entry.fetch(:input_url) }
  end

  def process(row, lookups)
    return { "status" => "invalid_record" } unless row.is_a?(Hash)
    digest = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
    return { "status" => "duplicate_record" } unless @seen.add?(digest)
    unless %w[is_official mentioned_in_paper mentioned_in_github].all? { |key| [true, false].include?(row[key]) }
      return { "status" => "invalid_flags" }
    end
    lookup = lookups[row["repo_url"]]
    return { "status" => "invalid_repository" } unless lookup
    lookup = ProjectRepositoryLookup.call([row["repo_url"]]).sole if @apply && lookup.fetch(:matches).empty?
    projects = lookup.fetch(:matches).map { |match| match.fetch(:project).fetch("id") }.uniq
    result = { "normalized_repository" => lookup.fetch(:normalized_url), "project_ids" => projects,
      "repository_match_sources" => lookup.fetch(:matches).map { |match| match.fetch(:source) }.uniq }
    return result.merge("status" => "repository_ambiguous") if projects.size > 1
    if projects.empty?
      status = repository_creation_status(row, result.fetch("normalized_repository"))
      return result.merge("status" => status) if status
    end
    unless row["paper_url"].is_a?(String) && row["paper_url"].match?(%r{\Ahttps?://paperswithcode\.com/paper/[^\s]+\z})
      return result.merge("status" => "invalid_paper_url")
    end

    arxiv = PaperIdentifier.arxiv_identifier(row["paper_arxiv_id"]) if row["paper_arxiv_id"].present?
    return result.merge("status" => "invalid_arxiv") if row["paper_arxiv_id"].present? && !arxiv
    urls = [row["paper_url_abs"], row["paper_url_pdf"]].select { |url| url.is_a?(String) }
    arxiv_ids = ([arxiv] + urls.filter_map { |url| PaperIdentifier.arxiv_from_url(url) }).compact.uniq
    return result.merge("status" => "paper_identifier_conflict") if arxiv_ids.size > 1
    arxiv = arxiv_ids.first
    keys = identity_keys(nil, urls)
    keys << "arxiv:#{arxiv}" if arxiv
    ids = keys.flat_map { |key| @paper_index.fetch(key, []).to_a }.uniq
    result["paper_ids"] = ids
    result["arxiv_id"] = arxiv if arxiv
    return result.merge("status" => "paper_ambiguous") if ids.size > 1
    return result.merge("status" => "paper_unresolved") if ids.empty? && !arxiv
    return result.merge("status" => "missing_title") if ids.empty? && !row["paper_title"].is_a?(String)
    return result.merge("status" => "missing_title") if ids.empty? && row["paper_title"].blank?

    if @apply
      import(row, projects.first, ids.first, arxiv, result)
    else
      key = [projects.first || result.fetch("normalized_repository"), ids.first || "arxiv:#{arxiv}"]
      existing = projects.any? && ids.first && ProjectPaper.exists?(project_id: projects.first, paper_id: ids.first)
      status = existing ? "would_merge_evidence" : @planned_pairs.add?(key) ? "would_create" : "would_merge_evidence"
      new_project = projects.empty? && !!@planned_projects.add?(result.fetch("normalized_repository"))
      result.merge("status" => status, "new_paper" => ids.empty? && !!@planned_papers.add?(arxiv),
        "new_project" => new_project, "sync_requested" => new_project)
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    (result || {}).merge("status" => "identity_conflict", "error" => error.message)
  end

  def import(row, project_id, paper_id, arxiv, result)
    paper = nil
    outcome = Paper.transaction(requires_new: true) do
      project = project_id ? Project.find(project_id) : discover_project!(row, result)
      project_id = project.id
      new_project = project.previously_new_record?
      identities = arxiv ? [{ source: "arxiv", identifier: arxiv }] : []
      Paper.lock_import_identifiers!(PaperIdentifier.lock_keys(identities) + ["pwc-project:#{project_id}"])
      current_ids = (Array(paper_id) + PaperIdentifier.paper_ids_for(identities)).uniq
      raise ArgumentError, "Multiple papers match the archive identifiers" if current_ids.size > 1
      new_paper = current_ids.empty?
      paper = current_ids.any? ? Paper.find(current_ids.first) :
        Paper.import_publication!(title: row.fetch("paper_title"), url: "https://arxiv.org/abs/#{arxiv}")
      PaperIdentifier.attach!(paper, identities)
      link = ProjectPaper.lock.find_or_initialize_by(project_id: project_id, paper_id: paper.id)
      link.role = "reference" if link.new_record?
      evidence = { "source" => SOURCE, "url" => row.fetch("paper_url"),
        "archive_url" => "#{DATASET}/tree/#{@snapshot}", "snapshot" => @snapshot,
        "license" => LICENSE, "attribution" => "Papers with Code; archived by pwc-archive",
        "relationship" => "historical_paper_repository_association", "record" => row }
      link.evidence = (link.evidence + [evidence]).uniq
      status = link.new_record? ? "created" : link.changed? ? "updated" : "unchanged"
      link.save! if link.changed?
      ExternalProjectSync.request(project_id) if new_project
      result.merge("status" => status, "project_ids" => [project_id], "paper_ids" => [paper.id],
        "role" => link.role, "new_paper" => new_paper, "new_project" => new_project, "sync_requested" => new_project)
    end
    @paper_index["arxiv:#{arxiv}"] = [paper.id] if arxiv
    outcome
  end

  def repository_creation_status(row, url)
    return "repository_hidden" if @discovery.excluded_match?(url)
    return "repository_unsupported" if @discovery.unsupported_port?(row["repo_url"]) || !@discovery.supported_repository?(url)
    return "repository_hidden" if @discovery.hidden_namespace?(url) || Project.new(url: url).hidden_owner?
  end

  def discover_project!(row, result)
    url = result.fetch("normalized_repository")
    Paper.lock_import_identifiers!(["pwc-repository:#{url}"])
    lookup = ProjectRepositoryLookup.call([row.fetch("repo_url")]).sole
    matches = lookup.fetch(:matches).map { |match| match.fetch(:project).fetch("id") }.uniq
    raise ArgumentError, "Multiple projects match the repository" if matches.size > 1
    if matches.one?
      result["repository_match_sources"] = lookup.fetch(:matches).map { |match| match.fetch(:source) }.uniq
      return Project.find(matches.sole)
    end
    status = repository_creation_status(row, url)
    raise ArgumentError, status if status

    Project.create_or_find_by!(url: url)
  end

  def paper_index
    index = Hash.new { |hash, key| hash[key] = Set.new }
    Paper.select(:id, :doi, :urls, :openalex_data).find_each do |paper|
      urls = Array(paper.urls) + Paper.openalex_urls(paper.openalex_data || {})
      identity_keys(paper.doi, urls).each { |key| index[key] << paper.id }
    end
    PaperIdentifier.where(source: "arxiv").pluck(:identifier, :paper_id).each { |identifier, id| index["arxiv:#{identifier}"] << id }
    index
  end

  def identity_keys(doi, urls)
    keys = []
    doi = normalize_doi(doi)
    keys << "doi:#{doi}" if doi
    urls = urls + (doi ? ["https://doi.org/#{doi}"] : [])
    urls.each do |url|
      uri = URI.parse(url.to_s)
      next unless %w[http https].include?(uri.scheme) && uri.userinfo.nil? && [80, 443].include?(uri.port)
      keys << "url:#{url}"
      arxiv = PaperIdentifier.arxiv_from_url(url)
      keys << "arxiv:#{arxiv}" if arxiv
      if %w[doi.org dx.doi.org].include?(uri.host&.downcase)
        value = normalize_doi(uri.path.delete_prefix("/"))
        keys << "doi:#{value}" if value
      end
    rescue URI::InvalidURIError
      next
    end
    keys.uniq
  end

  def normalize_doi(value)
    value = value.to_s.strip.downcase.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}, "")
    value if value.match?(%r{\A10\.\d{4,9}/\S+\z})
  end
end
