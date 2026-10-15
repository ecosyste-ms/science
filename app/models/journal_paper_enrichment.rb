class JournalPaperEnrichment < ApplicationRecord
  SOURCES = %w[jmlr jors jss].freeze
  DEFAULT_LIMIT = 5
  LEASE_DURATION = 10.minutes

  belongs_to :paper
  validates :status, :next_attempt_at, presence: true

  scope :due, -> {
    where("next_attempt_at <= ?", Time.current)
      .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current)
  }

  def self.cooldown_until
    where(status: %w[rate_limited unauthorized]).where("next_attempt_at > ?", Time.current).maximum(:next_attempt_at)
  end

  def self.enqueue(limit: DEFAULT_LIMIT)
    limit = Integer(limit)
    raise ArgumentError, "limit must be between 1 and 25" unless limit.between?(1, 25)
    return { queued: 0, status: "unconfigured" } if ENV["OPENALEX_API_KEY"].blank?
    cooldown = cooldown_until
    return { queued: 0, status: "cooldown", retry_at: cooldown } if cooldown

    ids = PaperIdentifier.where(source: SOURCES).where.not(paper_id: select(:paper_id))
      .distinct.order(:paper_id).limit(limit).pluck(:paper_id)
    ids.each do |paper_id|
      create_or_find_by!(paper_id: paper_id) { |record| record.next_attempt_at = Time.current }
    end
    queued = due.order(:next_attempt_at, :id).limit(limit).pluck(:id).count do |id|
      EnrichJournalPaperWorker.perform_async(id).present?
    end
    { queued: queued, status: "ready" }
  end

  def claim
    with_lock do
      return if next_attempt_at > Time.current || (lease_expires_at && lease_expires_at > Time.current)
      return if self.class.cooldown_until
      update!(lease_token: SecureRandom.uuid, lease_expires_at: LEASE_DURATION.from_now)
      lease_token
    end
  end

  def finish(token, status:, next_attempt_at:, error: nil, work: nil)
    with_lock do
      return unless lease_token == token
      if work
        result = Paper.import_openalex!(work)
        raise ArgumentError, "OpenAlex response resolved to another paper" unless result.fetch("paper_id") == paper_id
      end
      update!(status: status, checked_at: Time.current, next_attempt_at: next_attempt_at,
        last_error: error&.truncate(1000), lease_token: nil, lease_expires_at: nil)
    end
  end
end
