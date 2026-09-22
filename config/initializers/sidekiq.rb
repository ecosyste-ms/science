require 'sidekiq'
require 'sidekiq-status'
require 'sidekiq-unique-jobs'

Sidekiq.configure_client do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
  config.logger = Rails.logger if Rails.env.test?
  # accepts :expiration (optional)
  Sidekiq::Status.configure_client_middleware config, expiration: 60.minutes.to_i
end

Sidekiq.configure_server do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
  config.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
  SidekiqUniqueJobs::Server.configure(config)
  # accepts :expiration (optional)
  Sidekiq::Status.configure_server_middleware config, expiration: 60.minutes.to_i

  # accepts :expiration (optional)
  Sidekiq::Status.configure_client_middleware config, expiration: 60.minutes.to_i
end
