namespace :external_software do
  desc "Queue cached repository discovery and pending project syncs (LIMIT=100, maximum 100)"
  task discover: :environment do
    limit = Integer(ENV.fetch("LIMIT", "100"), 10)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.between?(1, 100)
    jid = DiscoverExternalRepositoriesWorker.perform_async(limit)
    syncs = ExternalProjectSync.enqueue_pending(limit: limit)
    puts JSON.generate(queued: jid.present?, limit: limit, project_syncs: syncs)
  end

  desc "Show cached repository discovery and project sync backlog"
  task discovery_status: :environment do
    puts JSON.generate(due: ExternalRepositoryDiscovery.due.reorder(nil).group(:source).count,
      failed: ExternalSoftwareRecord.where.not(discovery_error: nil).group(:source).count,
      pending_project_syncs: ExternalProjectSync.pending.count)
  end
end
