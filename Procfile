web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -C config/sidekiq.yml
journal: bundle exec rake swhids:consume
release: bundle exec rake db:migrate
