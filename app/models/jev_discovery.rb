class JevDiscovery < ApplicationRecord
  belongs_to :jev_run
  belongs_to :project, optional: true
  belongs_to :screen_request, class_name: "JevRequest", optional: true
  belongs_to :enrich_request, class_name: "JevRequest", optional: true
  validates :repository_url, :source, :sampling_method, :sample_group, presence: true
  validates :review_state, inclusion: { in: %w[unreviewed research negative uncertain] }
  validates :review_notes, length: { maximum: 4000 }

  def classification_for(screen, implementation)
    return "research_candidate" if implementation && implementation >= 0.8
    return "negative" if screen && screen <= 0.2 && (implementation.nil? || implementation <= 0.2)
    "uncertain"
  end

  def review!(state:, notes:, reviewer:)
    update!(review_state: state, review_notes: notes, reviewed_by: reviewer, reviewed_at: Time.current)
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
        review_state: "unreviewed", next_attempt_at: Time.current, processing_token: nil, lease_until: nil)
    end
  end
end
