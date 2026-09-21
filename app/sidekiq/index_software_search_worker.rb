class IndexSoftwareSearchWorker
  include Sidekiq::Worker

  def perform(project_id)
    SoftwareSearchIndexer.index(project_id)
  end
end
