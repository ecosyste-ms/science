class ExternalProjectSync < ApplicationRecord
  belongs_to :project

  scope :pending, -> { where("completed_at IS NULL OR requested_at > completed_at") }
  scope :due, -> {
    pending.where("next_attempt_at <= ?", Time.current)
      .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current)
  }

  def self.request(project_id)
    now = Time.current
    upsert_all([{ project_id: project_id, requested_at: now, next_attempt_at: now }],
      unique_by: :index_external_project_syncs_on_project_id,
      update_only: [:requested_at, :next_attempt_at], record_timestamps: false)
  end

  def self.enqueue_pending(limit: 100)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)
    ids = due.order(:next_attempt_at, :id).limit(limit).pluck(:id)
    ids.each { |id| SyncExternalProjectWorker.perform_async(id) }
    ids.size
  end

  def claim
    with_lock do
      return if completed_at && completed_at >= requested_at
      return if next_attempt_at > Time.current || (lease_expires_at && lease_expires_at > Time.current)
      update!(lease_token: SecureRandom.uuid, lease_expires_at: 1.hour.from_now)
      [lease_token, requested_at]
    end
  end

  def finish(token, requested, error: nil)
    with_lock do
      return unless lease_token == token
      attributes = { lease_token: nil, lease_expires_at: nil, last_error: error,
        next_attempt_at: error ? 1.hour.from_now : Time.current }
      # A newer request may have arrived while this sync was running.
      attributes[:completed_at] = requested unless error
      update!(attributes)
    end
  end
end
