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
end
