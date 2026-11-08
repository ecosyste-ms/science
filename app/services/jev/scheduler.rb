class Jev::Scheduler
  def run
    return unless Jev::Settings.enabled?
    Jev::Run.where(status: %w[running monitoring]).order(:id).find_each do |run|
      sampling_error = nil
      begin
        Jev::Sampler.new(run).seed unless run.sampling_complete?
      rescue Jev::Client::Error => error
        sampling_error = error.message
      end
      recover(run)
      enqueue(run, "screen")
      enqueue(run, "enrich")
      refresh(run) if run.sampling_complete?
      pending = run.discoveries.where.not(status: %w[complete excluded failed_screen failed_enrich enrichment_deferred])
      if run.sampling_complete? && !pending.exists?
        run.update!(status: "monitoring", completed_at: run.completed_at || Time.current)
      end
      run.update!(last_error: sampling_error)
    rescue StandardError => error
      run.update!(last_error: "#{error.class}: scheduler failed")
      Rails.logger.error(event: "jev_scheduler_error", run_id: run.id, error: error.class.name)
    end
  end

  def recover(run)
    run.discoveries.where("lease_until < ?", Time.current).find_each do |record|
      stage = record.status.include?("enrich") ? "enrich" : "screen"
      record.update!(status: "pending_#{stage}", processing_token: nil, lease_until: nil, next_attempt_at: Time.current)
    end
  end

  def enqueue(run, stage)
    if stage == "enrich"
      return unless run.sampling_complete? && !run.discoveries.where(status: %w[pending_screen queued_screen screening]).exists?
      used = run.discoveries.where.not(enriched_at: nil).count + run.discoveries.where(status: %w[queued_enrich enriching]).count
      remaining = [run.settings.fetch("max_enrichments") - used, 0].max
      limit = [run.settings.fetch("enrich_batch_size"), remaining].min
      if remaining.zero?
        run.discoveries.where(status: "pending_enrich").update_all(status: "enrichment_deferred", last_error: "Run enrichment limit reached", updated_at: Time.current)
      end
    else
      limit = run.settings.fetch("batch_size")
    end
    queued = run.discoveries.where(status: stage == "screen" ? %w[queued_screen screening] : %w[queued_enrich enriching]).count
    limit = [limit - queued, 0].max
    scope = run.discoveries.where(status: "pending_#{stage}").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
    order = stage == "enrich" ? Arel.sql("md5(id::text || #{ActiveRecord::Base.connection.quote(run.seed)})") : :id
    scope.order(control: :desc).order(order).limit(limit).each do |candidate|
      candidate.update!(status: "queued_#{stage}", lease_until: 10.minutes.from_now)
      Jev::DiscoveryWorker.set(queue: stage == "screen" ? "jev" : "jev_enrich").perform_async(candidate.id, stage)
    end
  end

  def refresh(run)
    run.discoveries.where(status: "complete").where("next_check_at <= ?", Time.current).order(:next_check_at).limit(50).each do |candidate|
      metadata = if candidate.project
        Jev::Evidence.metadata(project: candidate.project, url: candidate.repository_url)
      else
        repository = Jev::Evidence.get(Jev::Evidence.repository_endpoint(candidate.repository_url))
        Jev::Evidence.metadata(repository: repository, url: candidate.repository_url)
      end
      fingerprint = Jev::Evidence.fingerprint(metadata, project: candidate.project, repository: repository)
      changed = fingerprint != candidate.evidence_fingerprint || candidate.screen_request&.question_versions != Jev::Questions.versions("screen") ||
        candidate.screen_request&.model != run.settings.fetch("model") ||
        (candidate.enrich_request && candidate.enrich_request.question_versions != Jev::Questions.versions("enrich"))
      candidate.update!(next_check_at: run.settings.fetch("rescan_days").days.from_now,
        **(changed ? { evidence: { "metadata" => metadata }, evidence_fingerprint: fingerprint, status: "pending_screen",
          screen_attempts: 0, enrich_attempts: 0, strict_probability: nil, implementation_probability: nil,
          screen_request_id: nil, enrich_request_id: nil, screened_at: nil, enriched_at: nil, review_state: "unreviewed",
          review_purpose: nil, review_implementation: nil, review_catalogue_value: nil,
          classification: "uncertain", enrichment_selected: false, control: false, next_attempt_at: Time.current } : {}))
    rescue Jev::Client::Error => error
      candidate.update!(last_error: error.message, next_check_at: 1.day.from_now)
    end
  end
end
