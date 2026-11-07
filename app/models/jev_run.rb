class JevRun < ApplicationRecord
  has_many :jev_discoveries, dependent: :delete_all
  has_many :jev_requests, dependent: :restrict_with_exception
  validates :name, :seed, presence: true
  validates :name, uniqueness: true
  validates :target_count, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1_000_000 }
  validates :budget_usd, numericality: { greater_than: 0 }

  def self.start!(name:, target: 10_000, budget: 1, seed: SecureRandom.hex(12))
    create!(name: name, seed: seed, target_count: target, budget_usd: budget,
      settings: JevSettings.snapshot.merge("question_versions" => %w[screen enrich].to_h { |stage| [stage, JevQuestions.versions(stage)] }))
  end

  def statistics
    scope = jev_discoveries
    requests = jev_requests
    { id: id, name: name, status: status, target: target_count, sampled: scope.count,
      statuses: scope.group(:status).count, classifications: scope.group(:classification).count,
      sources: scope.group(:sample_group).count, screen_bands: scope.group(:screen_band).count,
      controls: scope.where(control: true).group(:screen_band).count,
      reviews: scope.group(:review_state).count, enrichment_selected: scope.where(enrichment_selected: true).count,
      request_statuses: requests.group(:status).count, input_tokens: requests.sum(:input_tokens), output_tokens: requests.sum(:output_tokens),
      api_attempts: requests.sum(:attempts),
      mean_latency_ms: requests.where(status: "succeeded").average(:latency_ms)&.to_f,
      requests_per_second: requests.where(status: "succeeded").count.fdiv([(completed_at || Time.current) - created_at, 1].max),
      failures: scope.where(status: %w[failed_screen failed_enrich]).count,
      failure_rate: scope.where(status: %w[failed_screen failed_enrich]).count.fdiv([scope.count, 1].max),
      enrichment_gaps: scope.where.not(enrichment_error: nil).count,
      spent_usd: spent_usd.to_f, reserved_usd: reserved_usd.to_f, budget_usd: budget_usd.to_f,
      completed_at: completed_at, last_error: last_error }
  end

  def reevaluate!
    with_lock do
      update!(settings: settings.merge(JevSettings.snapshot.slice("model")).merge(
        "question_versions" => %w[screen enrich].to_h { |stage| [stage, JevQuestions.versions(stage)] }), status: "running", completed_at: nil)
      jev_discoveries.update_all(status: "pending_screen", screen_attempts: 0, enrich_attempts: 0,
        strict_probability: nil, implementation_probability: nil, screen_request_id: nil, enrich_request_id: nil,
        screened_at: nil, enriched_at: nil, enrichment_selected: false, control: false,
        classification: "uncertain", review_state: "unreviewed", next_attempt_at: Time.current, lease_until: nil,
        processing_token: nil, last_error: nil, updated_at: Time.current)
    end
  end
end
