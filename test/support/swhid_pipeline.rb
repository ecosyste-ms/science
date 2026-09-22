module SwhidPipeline
  extend ActiveSupport::Concern

  included do
    setup do
      Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
      clear_swhid_batch
      @origin_stub = stub_request(:get, %r{\Ahttps://archive\.softwareheritage\.org/api/1/origin/.+/visits/})
        .to_return(status: 404)
    end

    teardown do
      clear_swhid_batch
    end
  end

  def clear_swhid_batch
    RepositoryScanWorker.clear
    CheckSwhidWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{RepositoryScanWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
    CheckSwhidBatchWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{CheckSwhidBatchWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
    Sidekiq.redis { |redis| redis.call("DEL", CheckSwhidBatchWorker::PENDING_KEY) }
    CheckSwhidOriginWorker.clear
    SidekiqUniqueJobs::Digests.new.delete_by_pattern("#{CheckSwhidOriginWorker.get_sidekiq_options.fetch('lock_prefix')}:*")
  end

  def perform_fetch(project_id)
    FetchSwhidWorker.new.perform(project_id)
    finish_swhid_checks
  end

  def drain_fetch
    FetchSwhidWorker.drain
    RepositoryScanWorker.drain
    finish_swhid_checks
  end

  def finish_swhid_checks
    CheckSwhidBatchWorker.perform_one if CheckSwhidBatchWorker.jobs.any?
    CheckSwhidArchivalWorker.jobs.select { |job| job["at"].nil? }.each do |job|
      Sidekiq::Queues.delete_for(job["jid"], job["queue"], job["class"])
      CheckSwhidArchivalWorker.process_job(job)
    end
    nil
  end
end
