class JevDiscoveryWorker
  include Sidekiq::Worker
  sidekiq_options queue: "jev", retry: false, lock: :until_executed, lock_ttl: 15.minutes.to_i,
    lock_prefix: "science:#{Rails.env}:jev"

  def perform(id, stage)
    raise ArgumentError, "Unknown Jev stage" unless %w[screen enrich].include?(stage)
    discovery = JevDiscovery.find_by(id: id)
    JevProcessor.new(discovery).perform(stage) if discovery
  end
end
