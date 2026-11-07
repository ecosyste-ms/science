class JevProcessor
  def initialize(discovery)
    @discovery = discovery
    @run = discovery.jev_run
  end

  def perform(stage)
    return unless JevSettings.enabled? && @run.status.in?(%w[running monitoring])
    token = SecureRandom.hex(16)
    claimed = false
    @discovery.with_lock do
      return if @discovery.lease_until&.future? && @discovery.status.in?(%w[screening enriching])
      return unless @discovery.status.in?(["pending_#{stage}", "queued_#{stage}"])
      @discovery.update!(status: stage == "screen" ? "screening" : "enriching", processing_token: token,
        lease_until: 10.minutes.from_now, "#{stage}_attempts" => @discovery.public_send("#{stage}_attempts") + 1)
      claimed = true
    end
    attributes = stage == "screen" ? screen : enrich(token)
    @discovery.class.where(id: @discovery.id, processing_token: token).update_all(attributes.merge(processing_token: nil, lease_until: nil, updated_at: Time.current))
  rescue JevLimiter::Busy
    defer(stage, token, 2.seconds, nil, decrement: true) if claimed
  rescue JevClient::BudgetExceeded, JevClient::ConfigurationError => error
    @run.update!(status: "paused", last_error: error.message)
    defer(stage, token, 1.hour, error.message, decrement: true) if claimed
  rescue StandardError => error
    message = safe_error(error)
    attempts = @discovery.reload.public_send("#{stage}_attempts")
    if claimed && attempts < @run.settings.fetch("max_attempts")
      defer(stage, token, @run.settings.fetch("retry_seconds").seconds * (2**(attempts - 1)), message)
    elsif claimed
      @discovery.class.where(id: @discovery.id, processing_token: token).update_all(status: "failed_#{stage}", last_error: message,
        lease_until: nil, processing_token: nil, updated_at: Time.current)
    end
  end

  def screen
    if @discovery.project && !Project.visible.where(id: @discovery.project_id).where("science_score < ? OR science_score IS NULL", Project::SCIENCE_SCORE_THRESHOLD).exists?
      return { status: "excluded", last_error: "Project is hidden or already above the Science Score threshold" }
    end
    request = JevClient.new(@run).call(stage: "screen", state: @discovery.evidence.fetch("metadata"))
    probability = request.response_body.dig("answers", "strict", "noul")
    band = probability >= 0.6 ? "promising" : probability > 0.2 ? "borderline" : "low"
    chance = band == "low" ? 0.05 : band == "borderline" ? 0.20 : 1.0
    draw = Digest::SHA256.hexdigest("#{@run.seed}:#{@discovery.repository_url}:enrich")[0, 13].to_i(16).fdiv(16**13)
    selected = draw < chance
    { strict_probability: probability, screen_request_id: request.id, screened_at: Time.current, screen_band: band,
      control: selected && band != "promising", control_probability: chance,
      enrichment_selected: selected, enrichment_reason: selected ? (band == "promising" ? "screen_probability" : "random_#{band}_control") : nil,
      status: selected ? "pending_enrich" : "complete", next_attempt_at: Time.current,
      classification: @discovery.classification_for(probability, nil), last_error: nil,
      next_check_at: @run.settings.fetch("rescan_days").days.from_now }
  end

  def enrich(token)
    if @discovery.evidence["enriched"]
      evidence, error = @discovery.evidence, @discovery.enrichment_error
    else
      evidence, error = JevEvidence.new.collect(@discovery)
      updated = @discovery.class.where(id: @discovery.id, processing_token: token).update_all(evidence: evidence, enrichment_error: error, updated_at: Time.current)
      return {} if updated.zero?
    end
    request = JevClient.new(@run).call(stage: "enrich", state: evidence.fetch("enriched"))
    probability = request.response_body.dig("answers", "implementation", "noul")
    { evidence: evidence, implementation_probability: probability, enrich_request_id: request.id, enriched_at: Time.current,
      enrichment_error: error, classification: @discovery.classification_for(@discovery.strict_probability, probability),
      status: "complete", last_error: nil, next_check_at: @run.settings.fetch("rescan_days").days.from_now }
  end

  def defer(stage, token, delay, error, decrement: false)
    attributes = { status: "pending_#{stage}", next_attempt_at: Time.current + delay, lease_until: nil, processing_token: nil, last_error: error, updated_at: Time.current }
    attributes["#{stage}_attempts"] = [@discovery.public_send("#{stage}_attempts") - 1, 0].max if decrement
    @discovery.class.where(id: @discovery.id, processing_token: token).update_all(attributes)
  end

  def safe_error(error)
    message = case error
    when JevClient::Error, JevLimiter::Busy then error.message
    else "#{error.class}: processing failed"
    end
    key = ENV["JEV_API_KEY"]
    message = message.gsub(key, "[FILTERED]") if key.present?
    message.to_s[0, 500]
  end
end
