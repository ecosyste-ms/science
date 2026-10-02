class ExternalSoftwareImport < ApplicationRecord
  LEASE_DURATION = 10.minutes
  PAGE_DELAY = 15.seconds

  validates :source, :started_at, :next_run_at, presence: true
  validates :page_size, numericality: { only_integer: true, in: 1..100 }

  def self.start_wikidata(after: nil, page_size: nil, restart: false)
    WikidataClient.validate_ids!([after]) if after
    if page_size && (!page_size.is_a?(Integer) || !page_size.between?(1, 100))
      raise ArgumentError, "page size must be between 1 and 100"
    end
    record = find_by(source: "wikidata")
    raise ArgumentError, "no completed import to restart" if restart && record.nil?
    record ||= create_or_find_by!(source: "wikidata") do |import|
      import.cursor = after
      import.page_size = page_size || 100
      import.started_at = Time.current
      import.next_run_at = Time.current
    end
    record.with_lock do
      if restart
        raise ArgumentError, "cannot restart an unfinished import; omit RESTART to resume" unless record.completed_at
        record.update!(cursor: after, page_size: page_size || 100, started_at: Time.current,
          completed_at: nil, pending_ids: [], pages_processed: 0, items_processed: 0,
          lease_token: nil, lease_expires_at: nil, next_run_at: Time.current, last_error: nil)
      elsif (after && after != record.cursor) || (page_size && page_size != record.page_size)
        raise ArgumentError, "import progress is already saved; omit AFTER and LIMIT to resume"
      end
    end
    record
  end

  def self.resumable_wikidata
    where(source: "wikidata", completed_at: nil).where("next_run_at <= ?", Time.current)
      .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current).first
  end

  def self.start_biotools(page_size: nil, restart: false)
    if page_size && (!page_size.is_a?(Integer) || !page_size.between?(1, BiotoolsClient::PAGE_SIZE))
      raise ArgumentError, "page size must be between 1 and 50"
    end
    record = find_by(source: "biotools")
    raise ArgumentError, "no completed import to restart" if restart && record.nil?
    record ||= create_or_find_by!(source: "biotools") do |import|
      import.cursor = "1"
      import.page_size = page_size || BiotoolsClient::PAGE_SIZE
      import.started_at = Time.current
      import.next_run_at = Time.current
    end
    record.with_lock do
      if restart
        raise ArgumentError, "cannot restart an unfinished import; omit RESTART to resume" unless record.completed_at
        record.update!(cursor: "1", page_size: page_size || BiotoolsClient::PAGE_SIZE, started_at: Time.current,
          completed_at: nil, pending_ids: [], pending_records: [], pending_next_cursor: nil, page_retrieved_at: nil,
          pages_processed: 0, items_processed: 0, lease_token: nil, lease_expires_at: nil,
          next_run_at: Time.current, last_error: nil)
      elsif page_size && page_size != record.page_size
        raise ArgumentError, "import progress is already saved; omit LIMIT to resume"
      end
    end
    record
  end

  def self.resumable_biotools
    where(source: "biotools", completed_at: nil).where("next_run_at <= ?", Time.current)
      .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current).first
  end

  def enqueue
    return if completed_at
    worker = source == "biotools" ? ImportBiotoolsWorker : ImportWikidataWorker
    worker.perform_at([next_run_at, lease_expires_at, Time.current].compact.max, id)
  end

  def claim
    with_lock do
      return if completed_at || next_run_at > Time.current || (lease_expires_at && lease_expires_at > Time.current)
      update!(lease_token: SecureRandom.uuid, lease_expires_at: Time.current + LEASE_DURATION)
      lease_token
    end
  end

  def save_page(token, ids)
    with_lock do
      return false unless lease_token == token
      update!(pending_ids: ids)
    end
  end

  def advance(token)
    with_lock do
      return unless lease_token == token
      finished = pending_ids.size < page_size
      update!(cursor: pending_ids.last || cursor, pages_processed: pages_processed + 1,
        items_processed: items_processed + pending_ids.size, pending_ids: [],
        completed_at: finished ? Time.current : nil, next_run_at: Time.current + PAGE_DELAY,
        lease_token: nil, lease_expires_at: nil, last_error: nil)
      next_run_at unless finished
    end
  end

  def save_biotools_page(token, records, next_page, retrieved_at)
    with_lock do
      return false unless lease_token == token
      update!(pending_ids: records.map { |record| BiotoolsClient.identifier(record["biotoolsID"]) },
        pending_records: records, pending_next_cursor: next_page&.to_s, page_retrieved_at: retrieved_at)
    end
  end

  def advance_biotools(token)
    with_lock do
      return unless lease_token == token
      finished = pending_next_cursor.nil?
      update!(cursor: pending_next_cursor || cursor, pages_processed: pages_processed + 1,
        items_processed: items_processed + pending_ids.size, pending_ids: [], pending_records: [],
        pending_next_cursor: nil, page_retrieved_at: nil, completed_at: finished ? Time.current : nil,
        next_run_at: Time.current + PAGE_DELAY, lease_token: nil, lease_expires_at: nil, last_error: nil)
      next_run_at unless finished
    end
  end

  def defer(token, retry_at, error)
    with_lock do
      return unless lease_token == token
      update!(next_run_at: [retry_at, Time.current + PAGE_DELAY].max, last_error: error.to_s.truncate(1000),
        lease_token: nil, lease_expires_at: nil)
      next_run_at
    end
  end

  def progress
    result = {
      source: source, after: cursor, page_size: page_size, pages_processed: pages_processed,
      items_processed: items_processed, pending_items: pending_ids.size, complete: completed_at.present?,
      started_at: started_at, completed_at: completed_at, next_run_at: completed_at ? nil : next_run_at,
      lease_expires_at: lease_expires_at, last_error: last_error,
    }
    result[:page] = result.delete(:after).to_i if source == "biotools"
    result
  end
end
