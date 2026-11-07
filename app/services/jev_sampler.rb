class JevSampler
  def initialize(run)
    @run = run
  end

  def seed
    @run.with_lock do
      return if @run.sampling_complete?
      state = @run.sampling_state.deep_dup
      unless state["local_done"]
        seed_local
        state["local_done"] = true
        @run.update!(sampling_state: state)
      end
      unless state["packages_done"]
        seed_packages
        state["packages_done"] = true
        @run.update!(sampling_state: state)
      end
    end
    seed_external
  end

  def seed_local
    target = @run.target_count
    groups = {
      "score_zero" => [Project.visible.where(science_score: 0), (target * 0.25).to_i],
      "score_low" => [Project.visible.where("science_score > 0 AND science_score < ?", Project::SCIENCE_SCORE_THRESHOLD), (target * 0.20).to_i],
      "score_unscored" => [Project.visible.where(science_score: nil), (target * 0.05).to_i]
    }
    groups.each do |name, (scope, size)|
      random_order(scope, size).pluck(:id).each_slice(100) do |ids|
        Project.where(id: ids).find_each do |project|
          url = JevEvidence.repository_url(project.url)
          next unless url
          add(url: url, project: project, group: name, source: "science", method: "seeded_hash_within_score_stratum",
            metadata: JevEvidence.metadata(project: project, url: url))
        end
      end
    end
  end

  def seed_packages
    count = @run.jev_discoveries.count
    packages = Package.visible.where(published_by_project_id: nil).where.not(repository_url: [nil, ""])
      .where("repository_url ~* ?", '^https://(github[.]com|gitlab[.]com|codeberg[.]org)/')
      .where("NOT EXISTS (SELECT 1 FROM projects WHERE projects.url = lower(packages.repository_url))")
      .where("NOT EXISTS (SELECT 1 FROM project_repository_aliases WHERE project_repository_aliases.url = lower(packages.repository_url))")
    random_order(packages, (@run.target_count * 0.25).to_i).pluck(:id).each_slice(100) do |ids|
      Package.where(id: ids).includes(:package_registry).find_each do |package|
        break if count >= @run.target_count
        url = JevEvidence.repository_url(package.repository_url)
        next unless url && absent?(url)
        candidate = add(url: url, group: "unlinked_package_#{package.package_registry.ecosystem.to_s.downcase}", source: "packages",
          method: "seeded_hash_supported_unlinked_stored_packages", metadata: JevEvidence.metadata(package: package, url: url),
          provenance: { "package_id" => package.id })
        count += 1 if candidate.previously_new_record?
      end
    end
  end

  def random_order(scope, limit)
    seed = ActiveRecord::Base.connection.quote(@run.seed)
    scope.reorder(Arel.sql("md5(#{scope.table_name}.id::text || #{seed})")).limit(limit)
  end

  def seed_external
    state = @run.reload.sampling_state.deep_dup
    page_index = state.fetch("external_index", 0)
    pages = external_pages
    3.times do
      break if @run.jev_discoveries.count >= @run.target_count || page_index >= pages.size
      page, order = pages[page_index]
      url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories"
      records = JevEvidence.get(url, per_page: 100, page: page, sort: "full_name", order: order)
      raise JevClient::Error, "Unexpected repository list" unless records.is_a?(Array)
      records.shuffle(random: Random.new(Digest::SHA256.hexdigest("#{@run.seed}:#{page_index}").to_i(16))).each do |repository|
        break if @run.jev_discoveries.count >= @run.target_count
        next if repository["fork"]
        candidate = JevEvidence.repository_url("https://github.com/#{repository['full_name']}")
        next unless candidate && absent?(candidate)
        add(url: candidate, group: "external_repositories", source: "repos", method: "seeded_random_name_page",
          metadata: JevEvidence.metadata(repository: repository, url: candidate),
          provenance: { "endpoint" => url, "page" => page, "order" => order,
            "page_frame" => "1..100 within ascending/descending names", "repository" => repository.slice(*JevEvidence::REPOSITORY_FIELDS) })
      end
      page_index += 1
      @run.update!(sampling_state: state.merge("external_index" => page_index))
    end
    if @run.jev_discoveries.count >= @run.target_count || page_index >= pages.size
      @run.update!(sampling_complete: true, sampling_state: @run.sampling_state.merge("frame_exhausted" => page_index >= pages.size))
    end
  end

  def external_pages
    random = Random.new(Digest::SHA256.hexdigest(@run.seed).to_i(16))
    %w[asc desc].flat_map { |order| (1..100).map { |page| [page, order] } }.shuffle(random: random)
  end

  def absent?(url)
    !Project.where(url: url).exists? && !ProjectRepositoryAlias.where(url: url).exists?
  end

  def add(url:, group:, source:, method:, metadata:, project: nil, provenance: {})
    if project
      provenance = provenance.merge("science_score" => project.science_score,
        "stored_score_breakdown" => project.read_attribute(:science_score_breakdown))
    end
    @run.jev_discoveries.create_or_find_by!(repository_url: url) do |candidate|
      candidate.assign_attributes(project: project, source: source, sample_group: group, sampling_method: method,
        source_metadata: provenance, evidence: { "metadata" => metadata },
        evidence_fingerprint: JevEvidence.fingerprint(metadata, project: project, repository: provenance["repository"]), next_attempt_at: Time.current)
    end
  end
end
