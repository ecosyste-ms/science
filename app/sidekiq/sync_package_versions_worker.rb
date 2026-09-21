class SyncPackageVersionsWorker
  include Sidekiq::Worker

  sidekiq_options retry: 3

  def perform(package_id)
    package = Package.version_importable.find_by(id: package_id)
    PackageVersionSync.new(package).sync! if package
  end
end
