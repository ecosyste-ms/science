class SwhidEnqueuer
  CURSORS_KEY = "science:#{Rails.env}:swhid-enqueue-cursors"

  def initialize(scan_limit: 5, check_limit: 500, archival_limit: 100)
    @scan_limit = Integer(scan_limit.to_s, 10)
    @check_limit = Integer(check_limit.to_s, 10)
    @archival_limit = Integer(archival_limit.to_s, 10)
    raise ArgumentError, "SCAN_LIMIT must be 1..100" unless @scan_limit.between?(1, 100)
    raise ArgumentError, "CHECK_LIMIT must be 1..1000" unless @check_limit.between?(1, 1_000)
    raise ArgumentError, "ARCHIVAL_LIMIT must be 1..1000" unless @archival_limit.between?(1, 1_000)
  end

  def enqueue
    counts = {
      scans: enqueue_page("scans", projects.needing_swhids, @scan_limit) { |id| RepositoryScanWorker.perform_async(id) },
      scan_retries: enqueue_page("scan_retries", projects.retryable_swhids, @scan_limit) { |id| RepositoryScanWorker.perform_async(id) }
    }
    SwhidApi.check_rate_limit!
    counts[:checks] = enqueue_page("checks", checks, @check_limit) do |id|
      CheckSwhidBatchWorker.enqueue(id)
      true
    end
    if Sidekiq.redis { |redis| redis.call("ZCARD", CheckSwhidBatchWorker::PENDING_KEY) }.positive?
      CheckSwhidBatchWorker.perform_in(CheckSwhidBatchWorker::BATCH_DELAY)
    end
    counts[:archival] = enqueue_page("archival", archival, @archival_limit) { |id| CheckSwhidArchivalWorker.perform_async(id) }
    counts
  rescue SwhidApi::RateLimited
    counts.merge(checks: 0, archival: 0)
  end

  def projects
    Project.visible.scientific.with_repository.where("COALESCE(repository->>'gated', 'false') IN ('false', '')")
  end

  def checks
    projects.where(<<~SQL, now: Time.current)
      EXISTS (
        SELECT 1 FROM jsonb_array_elements(jsonb_build_array(swhids->'revision', swhids->'directory')) AS objects(object)
        WHERE object->>'status' = 'success' AND NULLIF(BTRIM(object->>'swhid'), '') IS NOT NULL
          AND COALESCE(
            NULLIF(object #>> '{archive,retry_at}', '')::timestamptz,
            NULLIF(CASE WHEN object #>> '{archive,status}' = 'error'
              THEN object #>> '{archive,attempted_at}' ELSE object #>> '{archive,checked_at}' END, '')::timestamptz
              + CASE WHEN object #>> '{archive,status}' = 'error' THEN INTERVAL '1 hour' ELSE INTERVAL '7 days' END,
            '-infinity'::timestamptz
          ) <= :now
      )
    SQL
  end

  def archival
    projects.where(<<~SQL, now: Time.current, origin_pattern: "^https?://[^/[:space:]]+")
      (
        swhids->'archival'->>'status' IN ('submitting', 'pending', 'rate_limited', 'authentication_failed')
        AND NULLIF(swhids->'archival'->>'next_check_at', '')::timestamptz <= :now
      ) OR (
        swhids->'archival'->>'status' = 'uncertain'
        AND swhids->'archival'->>'error' = 'HTTP 429' AND swhids->'archival'->>'id' IS NULL
      ) OR (
        (swhids->'archival' IS NULL OR swhids->'archival' = 'null'::jsonb)
        AND swhids->>'origin' ~* :origin_pattern
        AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(jsonb_build_array(swhids->'revision', swhids->'directory')) AS objects(object)
          WHERE object->>'status' = 'success' AND NULLIF(BTRIM(object->>'swhid'), '') IS NOT NULL
            AND object #>> '{archive,status}' = 'not_found'
        )
      )
    SQL
  end

  def enqueue_page(name, scope, limit)
    cursor = Sidekiq.redis { |redis| redis.call("HGET", CURSORS_KEY, name) }.to_i
    ids = scope.where("projects.id > ?", cursor).order(:id).limit(limit).pluck(:id)
    ids = scope.order(:id).limit(limit).pluck(:id) if ids.empty? && cursor.positive?
    queued = ids.count { |id| yield id }
    Sidekiq.redis { |redis| redis.call("HSET", CURSORS_KEY, name, ids.last) } if ids.any?
    queued
  end
end
