class ResearchOrganizationOwnerBackfill
  def self.call(limit: 100, restart: false, max_batches: nil, progress: nil)
    raise ArgumentError, "limit must be between 1 and 500" unless limit.is_a?(Integer) && limit.between?(1, 500)
    raise ArgumentError, "max_batches must be positive" if max_batches && (!max_batches.is_a?(Integer) || !max_batches.positive?)
    import = ResearchOrganizationImport.find_by!(current: true)
    import.with_lock do
      if restart
        import.update!(owner_cursor: 0, owner_upper_bound: nil, owner_counts: {}, backfill_completed_at: nil)
      end
      import.update!(owner_upper_bound: Owner.organizations.visible.maximum(:id) || 0) if import.owner_upper_bound.nil?
    end
    batches = 0
    loop do
      import.with_lock do
        raise ArgumentError, "Current ROR release changed; rerun the backfill" unless import.current?
        break if import.backfill_completed_at
        owners = Owner.organizations.visible.where("id > ? AND id <= ?", import.owner_cursor, import.owner_upper_bound)
          .order(:id).limit(limit).to_a
        counts = import.owner_counts.dup
        owners.each do |owner|
          outcome = ResearchOrganizationOwnerMatcher.call(owner)
          counts[outcome] = counts.fetch(outcome, 0) + 1
        end
        import.update!(owner_cursor: owners.last&.id || import.owner_cursor, owner_counts: counts,
          backfill_completed_at: owners.size < limit ? Time.current : nil)
      end
      batches += 1
      progress&.call("ROR owner backfill: #{import.owner_counts.inspect}; cursor=#{import.owner_cursor}")
      break if import.backfill_completed_at || (max_batches && batches >= max_batches)
    end
    import.progress
  end
end
