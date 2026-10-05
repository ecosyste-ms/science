class ResearchOrganizationImport < ApplicationRecord
  LEASE_DURATION = 10.minutes

  validates :source_version, :checksum, :retrieved_at, presence: true

  def claim
    with_lock do
      return if completed_at || lease_expires_at&.future?
      update!(lease_token: SecureRandom.uuid, lease_expires_at: LEASE_DURATION.from_now)
      lease_token
    end
  end

  def progress
    { source_version: source_version, records_processed: records_processed, byte_offset: byte_offset,
      current: current, complete: completed_at.present?, last_error: last_error,
      owner_cursor: owner_cursor, owner_counts: owner_counts, backfill_complete: backfill_completed_at.present? }
  end
end
