require "digest"
require "fileutils"
require "tempfile"

class ScienceCohortExport
  def initialize(output:, batch_size: 250, progress: nil)
    raise ArgumentError, "OUTPUT is required" unless output.is_a?(String) && output.present?

    @output = File.expand_path(output)
    @batch_size = Integer(batch_size.to_s, 10, exception: false)
    raise ArgumentError, "batch size must be between 1 and 1000" unless @batch_size&.between?(1, 1000)

    @progress = progress
  end

  def export
    raise Errno::EEXIST, @output if File.exist?(@output) || File.symlink?(@output)

    FileUtils.mkdir_p(File.dirname(@output))
    counts = { projects: 0, packages: 0 }
    snapshot_id = SecureRandom.uuid
    Tempfile.create([".science-cohort-", ".jsonl"], File.dirname(@output)) do |file|
      Project.transaction(isolation: :repeatable_read) do
        Project.connection.execute("SET TRANSACTION READ ONLY")
        Project.uncached do
          write(file, "snapshot", {
            snapshot_id: snapshot_id, started_at: Time.current.utc.iso8601(6),
            source_isolation: "repeatable_read, read_only",
            selection: { projects: "visible scientific projects", minimum_science_score: Project::SCIENCE_SCORE_THRESHOLD,
              packages: "ranked direct scientific dependencies", minimum_publisher_score: Package::MINIMUM_REPOSITORY_SCIENCE_SCORE },
            exporter_sha256: Digest::SHA256.file(__FILE__).hexdigest
          })
          ProjectSearchSeeds.scope.select(:swhids).reorder(nil).find_in_batches(batch_size: @batch_size) do |projects|
            projects.each do |project|
              write(file, "project", ProjectSearchSeeds.new(project).as_json.merge(swhids: ProjectSwhidEvidence.new(project).as_json))
              counts[:projects] += 1
            end
            @progress&.call(counts.dup)
          end
          Package.in_batches(of: @batch_size) do |batch|
            Package.ranked_by_scientific_dependents(package_ids: batch.pluck(:id)).reorder(:id).each do |package|
              write(file, "package", {
                id: package.id, name: package.name, purl: package.purl, repository_url: package.repository_url,
                registry: package.package_registry.name, ecosystem: package.package_registry.ecosystem,
                published_by_project_id: package.published_by_project_id,
                scientific_projects_count: package.scientific_dependents_count.to_i,
                repository_science_score: package.repository_science_score&.to_f,
                updated_at: package.updated_at
              })
              counts[:packages] += 1
            end
            @progress&.call(counts.dup)
          end
          write(file, "complete", { snapshot_id: snapshot_id, completed_at: Time.current.utc.iso8601(6), counts: counts })
        end
      end
      file.flush
      file.fsync
      File.link(file.path, @output)
    end
    { output: @output, snapshot_id: snapshot_id, counts: counts, sha256: Digest::SHA256.file(@output).hexdigest }
  end

  def write(file, type, data)
    file.puts(JSON.generate(type: type, data: data))
  end
end
