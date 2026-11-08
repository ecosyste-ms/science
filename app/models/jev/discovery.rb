class Jev::Discovery < ApplicationRecord
  REVIEW_PURPOSES = { "scientific" => "Scientific", "general_purpose" => "General purpose", "educational" => "Educational",
    "non_scientific" => "Non-scientific", "uncertain" => "Uncertain" }.freeze
  REVIEW_IMPLEMENTATIONS = { "supported" => "Supported", "absent" => "Absent", "uncertain" => "Uncertain" }.freeze
  REVIEW_CATALOGUE_VALUES = { "distinct_candidate" => "Potential distinct addition", "already_represented" => "Already represented",
    "existing_relationship" => "Related software or variant", "uncertain" => "Uncertain", "not_applicable" => "Not applicable" }.freeze
  belongs_to :run, class_name: "Jev::Run", foreign_key: :jev_run_id
  belongs_to :project, optional: true
  belongs_to :screen_request, class_name: "Jev::Request", optional: true
  belongs_to :enrich_request, class_name: "Jev::Request", optional: true
  scope :publicly_accessible, -> { where(project_id: nil).or(where(project_id: Project.visible.select(:id))) }
  validates :repository_url, :source, :sampling_method, :sample_group, presence: true
  validates :review_state, inclusion: { in: %w[unreviewed research negative uncertain] }
  validates :review_notes, length: { maximum: 4000 }
  validates :review_purpose, inclusion: { in: REVIEW_PURPOSES.keys }, allow_nil: true
  validates :review_implementation, inclusion: { in: REVIEW_IMPLEMENTATIONS.keys }, allow_nil: true
  validates :review_catalogue_value, inclusion: { in: REVIEW_CATALOGUE_VALUES.keys }, allow_nil: true

  def classification_for(screen, implementation)
    return "research_candidate" if implementation && implementation >= 0.8
    return "negative" if screen && screen <= 0.2 && (implementation.nil? || implementation <= 0.2)
    "uncertain"
  end

  def review!(state:, notes:, reviewer:, purpose: review_purpose, implementation: review_implementation, catalogue_value: review_catalogue_value)
    update!(review_state: state, review_notes: notes, reviewed_by: reviewer, reviewed_at: Time.current,
      review_purpose: purpose.presence, review_implementation: implementation.presence, review_catalogue_value: catalogue_value.presence)
  end

  def resolve_repository!
    with_lock do
      update!(evidence: evidence.merge("repository_identity" => Jev::RepositoryIdentity.call(self)))
    end
  end

  def retry_evidence!
    with_lock do
      raise ArgumentError, "Evidence collection is still in progress" unless status == "complete" && enrichment_error.present?
      previous = { "error" => enrichment_error, "request_id" => enrich_request_id,
        "revision" => evidence["revision"], "collected_at" => evidence["collected_at"] }
      history = Array(evidence["previous_collections"]).last(9) + [previous]
      update!(evidence: { "metadata" => evidence.fetch("metadata"), "previous_collections" => history },
        status: "pending_enrich", classification: classification_for(strict_probability, nil), implementation_probability: nil,
        enrich_request_id: nil, enriched_at: nil, enrichment_error: nil, enrich_attempts: 0, last_error: nil,
        review_state: "unreviewed", review_purpose: nil, review_implementation: nil, review_catalogue_value: nil,
        next_attempt_at: Time.current, processing_token: nil, lease_until: nil)
    end
  end
end
