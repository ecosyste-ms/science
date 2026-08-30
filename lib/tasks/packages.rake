namespace :packages do
  desc "Sync package registries from packages.ecosyste.ms"
  task sync_registries: :environment do
    result = PackageRegistry.sync_from_ecosystems!
    puts "Package registries: #{result.inspect}"
  end
end
