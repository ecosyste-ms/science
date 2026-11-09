class Catalogue::Admission < ApplicationRecord
  DECISIONS = { "accepted" => "Approve admission", "deferred" => "Defer admission", "rejected" => "Reject admission" }.freeze

  belongs_to :project, optional: true, touch: true
  belongs_to :source_discovery, class_name: "Jev::Discovery", optional: true
  validates :project, presence: true, on: :create
  validates :project_id, uniqueness: true, allow_nil: true
  validates :decision, inclusion: { in: DECISIONS.keys }
  validates :repository_url, :reason, :reviewed_by, :reviewed_at, presence: true
  validates :reason, length: { maximum: 4000 }
  validate :visible_project

  scope :accepted, -> { where(decision: "accepted").where.not(project_id: nil) }
  scope :new_entries, -> { accepted.where("evidence @> ?::jsonb", { new_catalogue_entry: true }.to_json) }

  after_commit :refresh_membership, on: %i[create update], if: :saved_change_to_decision?

  def self.record!(project:, decision:, reason:, reviewer:, source_discovery: nil)
    project.with_lock do
      record = find_or_initialize_by(project_id: project.id)
      source_discovery ||= record.source_discovery
      attributes = { "decision" => decision.to_s, "reason" => reason.to_s.strip,
        "reviewed_by" => reviewer.to_s.strip, "source_discovery_id" => source_discovery&.id }
      if record.persisted? && attributes.all? { |key, value| record[key] == value }
        record
      else
        before = project.catalogued?
        after = project.science_score.to_f >= Project::SCIENCE_SCORE_THRESHOLD || decision.to_s == "accepted"
        continuing = record.persisted? && record.accepted? && decision.to_s == "accepted"
        new_entry = continuing ? record.evidence["new_catalogue_entry"] : !before && after
        entry_source = continuing ? record.evidence["entry_source_discovery_id"] : source_discovery&.id
        previous = record.snapshot if record.persisted?
        record.assign_attributes(attributes.merge("repository_url" => project.url, "reviewed_at" => Time.current,
          "history" => record.history + Array.wrap(previous),
          "evidence" => { "science_score" => project.science_score, "included_before" => before,
            "included_after" => after, "new_catalogue_entry" => new_entry,
            "entry_source_discovery_id" => entry_source,
            "source_revision" => source_discovery&.evidence&.[]("revision") }))
        record.save!
        project.association(:catalogue_admission).reset
        record
      end
    end
  end

  def visible_project
    errors.add(:project, "has a hidden owner") if project&.hidden_owner?
  end

  def accepted?
    decision == "accepted"
  end

  def snapshot
    attributes.slice("decision", "reason", "reviewed_by", "reviewed_at", "repository_url", "source_discovery_id", "evidence")
  end

  def public_summary
    { decision: decision, reason: reason, reviewed_at: reviewed_at, source_discovery_id: source_discovery_id,
      included_before: evidence["included_before"], included_after: evidence["included_after"],
      new_catalogue_entry: evidence["new_catalogue_entry"] }
  end

  def refresh_membership
    return unless project

    project.enqueue_software_search_index
    project.refresh_public_evidence_counts
    project.sync_async if accepted?
  end
end
