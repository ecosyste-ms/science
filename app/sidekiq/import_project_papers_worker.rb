class ImportProjectPapersWorker
  include Sidekiq::Worker

  sidekiq_options queue: :openalex, lock: :until_executed, lock_ttl: 1.hour.to_i

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    report = project.import_papers
    logger.info("Paper import for project #{project_id}: #{report.fetch('import_summary').inspect}")
    # Import errors are identity conflicts that fail the same way on every retry.
    report.fetch("candidates").select { |row| row.dig("import", "status") == "error" }.each do |row|
      logger.warn("Paper import conflict for project #{project_id}: #{row.dig('import', 'reason')}")
    end
    errors = report.fetch("candidates").select { |row| row["assessment"] == "error" }
    raise "Paper import failed for #{errors.size} candidates on project #{project_id}" if errors.any?
    report.fetch("import_summary")
  end
end
