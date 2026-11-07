class Jev::Sampler
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
          url = Jev::Evidence.repository_url(project.url)
          next unless url
          add(url: url, project: project, group: name, source: "science", method: "seeded_hash_within_score_stratum",
            metadata: Jev::Evidence.metadata(project: project, url: url))
        end
      end
    end
  end

  def seed_packages
    count = @run.discoveries.count
    packages = Package.visible.where(published_by_project_id: nil).where.not(repository_url: [nil, ""])
      .where("repository_url ~* ?", '^https://(github[.]com|gitlab[.]com|codeberg[.]org)/')
      .where("NOT EXISTS (SELECT 1 FROM projects WHERE projects.url = lower(packages.repository_url))")
      .where("NOT EXISTS (SELECT 1 FROM project_repository_aliases WHERE project_repository_aliases.url = lower(packages.repository_url))")
    random_order(packages, (@run.target_count * 0.25).to_i).pluck(:id).each_slice(100) do |ids|
      Package.where(id: ids).includes(:package_registry).find_each do |package|
        break if count >= @run.target_count
        url = Jev::Evidence.repository_url(package.repository_url)
        next unless url && absent?(url)
        candidate = add(url: url, group: "unlinked_package_#{package.package_registry.ecosystem.to_s.downcase}", source: "packages",
          method: "seeded_hash_supported_unlinked_stored_packages", metadata: Jev::Evidence.metadata(package: package, url: url),
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
    return seed_owners if @run.settings["external_sampling"] == "owner_time"
    state = @run.reload.sampling_state.deep_dup
    page_index = state.fetch("external_index", 0)
    pages = external_pages
    3.times do
      break if @run.discoveries.count >= @run.target_count || page_index >= pages.size
      page, order = pages[page_index]
      url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories"
      records = Jev::Evidence.get(url, per_page: 100, page: page, sort: "full_name", order: order)
      raise Jev::Client::Error, "Unexpected repository list" unless records.is_a?(Array)
      records.shuffle(random: Random.new(Digest::SHA256.hexdigest("#{@run.seed}:#{page_index}").to_i(16))).each do |repository|
        break if @run.discoveries.count >= @run.target_count
        next if repository["fork"]
        candidate = Jev::Evidence.repository_url("https://github.com/#{repository['full_name']}")
        next unless candidate && absent?(candidate)
        add(url: candidate, group: "external_repositories", source: "repos", method: "seeded_random_name_page",
          metadata: Jev::Evidence.metadata(repository: repository, url: candidate),
          provenance: { "endpoint" => url, "page" => page, "order" => order,
            "page_frame" => "1..100 within ascending/descending names", "repository" => repository.slice(*Jev::Evidence::REPOSITORY_FIELDS) })
      end
      page_index += 1
      @run.update!(sampling_state: state.merge("external_index" => page_index))
    end
    if @run.discoveries.count >= @run.target_count || page_index >= pages.size
      @run.update!(sampling_complete: true, sampling_state: @run.sampling_state.merge("frame_exhausted" => page_index >= pages.size))
    end
  end

  def seed_owners
    Jev::Run.with_connection do |connection|
      acquired = connection.select_value("SELECT pg_try_advisory_lock(7349413, #{@run.id})")
      return unless acquired
      begin
        seed_owner_windows
      ensure
        connection.execute("SELECT pg_advisory_unlock(7349413, #{@run.id})")
      end
    end
  end

  def seed_owner_windows
    state = @run.reload.sampling_state.deep_dup
    unless state["owner_frame"]
      host = Jev::Evidence.get("https://repos.ecosyste.ms/api/v1/hosts/GitHub")
      start = Time.iso8601(host.fetch("created_at"))
      finish = Time.current
      raise Jev::Client::Error, "Invalid owner sampling dates" unless start < finish
      state["owner_frame"] = { "start" => start.iso8601, "finish" => finish.iso8601,
        "owners_count" => host["owners_count"], "window_limit" => @run.settings.fetch("owner_windows") }
      @run.update!(sampling_state: state)
    end
    3.times do
      break if @run.discoveries.count >= @run.target_count
      index = state.fetch("owner_window_index", 0)
      break if index >= state.fetch("owner_frame").fetch("window_limit")
      unless state["owner_window"]
        frame = state.fetch("owner_frame")
        start, finish = frame.values_at("start", "finish").map { |value| Time.iso8601(value) }
        random = Random.new(Digest::SHA256.hexdigest("#{@run.seed}:owner-window:#{index}").to_i(16))
        after = Time.at(start.to_f + random.rand * (finish - start)).utc.iso8601(6)
        owners = Jev::Evidence.get("https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners",
          per_page: 20, page: 1, sort: "created_at", order: "asc", created_after: after)
        raise Jev::Client::Error, "Unexpected owner list" unless owners.is_a?(Array)
        selected = owners.select { |owner| owner.is_a?(Hash) && owner["login"].to_s.match?(/\A[a-z0-9-]{1,39}\z/i) }
          .shuffle(random: random).first(3).map { |owner| owner.slice("login", "kind", "created_at", "repositories_count") }
        state["owner_window"] = { "after" => after, "owners" => selected, "owner_index" => 0 }
        @run.update!(sampling_state: state)
      end
      window = state.fetch("owner_window")
      owner_index = window.fetch("owner_index")
      if owner_index >= window.fetch("owners").size
        state.delete("owner_window")
        state["owner_window_index"] = index + 1
        @run.update!(sampling_state: state)
        next
      end
      owner = window.fetch("owners").fetch(owner_index)
      url = "https://repos.ecosyste.ms/api/v1/hosts/GitHub/owners/#{owner.fetch('login')}/repositories"
      order = Digest::SHA256.hexdigest("#{@run.seed}:#{index}:#{owner_index}").to_i(16).even? ? "asc" : "desc"
      begin
        repositories = Jev::Evidence.get(url, per_page: 100, page: 1, sort: "created_at", order: order, fork: false)
        raise Jev::Client::Error, "Unexpected owner repository list" unless repositories.is_a?(Array)
        random = Random.new(Digest::SHA256.hexdigest("#{@run.seed}:#{index}:#{owner_index}:repositories").to_i(16))
        repositories.shuffle(random: random).reject { |repository| repository["fork"] }.first(10).each do |repository|
          break if @run.discoveries.count >= @run.target_count
          candidate = Jev::Evidence.repository_url("https://github.com/#{repository['full_name']}")
          next unless candidate && absent?(candidate)
          add(url: candidate, group: "external_owner_#{owner['kind'].presence || 'unknown'}", source: "repos",
            method: "seeded_owner_time_window", metadata: Jev::Evidence.metadata(repository: repository, url: candidate),
            provenance: { "endpoint" => url, "page" => 1, "order" => order, "window_index" => index,
              "created_after" => window.fetch("after"), "owner" => owner, "owner_frame" => state.fetch("owner_frame"),
              "page_frame" => "Three of 20 owners after a seeded time cutoff; up to ten of 100 repositories per owner",
              "repository" => repository.slice(*Jev::Evidence::REPOSITORY_FIELDS) })
        end
      rescue Jev::Client::Error => error
        window["attempts"] = window.fetch("attempts", 0) + 1
        @run.update!(sampling_state: state)
        raise unless error.message.match?(/HTTP (?:404|410)\b/) || window["attempts"] >= @run.settings.fetch("max_attempts")
        state["owner_errors"] = Array(state["owner_errors"]).last(19) + [{ "owner" => owner.fetch("login"), "error" => error.message, "at" => Time.current.iso8601 }]
        state["owner_error_count"] = state.fetch("owner_error_count", 0) + 1
      end
      window["owner_index"] = owner_index + 1
      window.delete("attempts")
      @run.update!(sampling_state: state)
    end
    exhausted = state.fetch("owner_window_index", 0) >= state.fetch("owner_frame").fetch("window_limit")
    if @run.discoveries.count >= @run.target_count || exhausted
      @run.update!(sampling_complete: true, sampling_state: state.merge("frame_exhausted" => exhausted))
    end
  rescue KeyError, ArgumentError
    raise Jev::Client::Error, "Invalid owner sampling metadata"
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
    @run.discoveries.create_or_find_by!(repository_url: url) do |candidate|
      candidate.assign_attributes(project: project, source: source, sample_group: group, sampling_method: method,
        source_metadata: provenance, evidence: { "metadata" => metadata },
        evidence_fingerprint: Jev::Evidence.fingerprint(metadata, project: project, repository: provenance["repository"]), next_attempt_at: Time.current)
    end
  end
end
