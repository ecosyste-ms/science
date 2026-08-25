web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -C config/sidekiq.yml
brief_worker: bundle exec sidekiq -C config/sidekiq_brief.yml
release: bundle exec rake db:migrate
