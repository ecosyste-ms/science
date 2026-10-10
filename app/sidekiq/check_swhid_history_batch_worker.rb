class CheckSwhidHistoryBatchWorker
  include Sidekiq::Worker

  sidekiq_options queue: "swh_api", retry: 3, lock: :until_executing,
    lock_prefix: "science:#{Rails.env}:swhid-history-batch"

  def perform(project_ids)
    raise ArgumentError, "Too many projects" unless project_ids.is_a?(Array) && project_ids.size.between?(1, CheckSwhidHistoryWorker::BATCH_SIZE)

    SwhidApi.check_rate_limit!
    checks = SwhidHistoryChecker.eligible.where(id: project_ids).filter_map do |project|
      next unless project.swhids["history_archive"]

      history = SwhidHistoryChecker.new(project)
      pending = history.pending.first(SwhidHistoryChecker::MAX_CHECKS)
      [history, SwhidArchiveChecker.new(nil), pending] if pending.any?
    end
    SwhidArchiveChecker.check_batch(checks.map { |_, checker, objects| [checker, objects] })
    checks.each do |history, _, _|
      history.update_status
      history.persist
    end
    rate_limit = checks.filter_map { |_, checker, _| checker.rate_limit }.first
    raise rate_limit if rate_limit
  rescue SwhidApi::RateLimited => error
    self.class.perform_at(SwhidApi.retry_job_at(error), project_ids)
  end
end
