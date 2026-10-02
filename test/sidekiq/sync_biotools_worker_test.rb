require "test_helper"
require_relative "../support/biotools_pipeline"

class SyncBiotoolsWorkerTest < ActiveSupport::TestCase
  include BiotoolsPipeline

  setup do
    @project = Project.create!(url: "https://github.com/scverse/scanpy", science_score: 42)
    @project.repository_aliases.create!(url: "https://github.com/theislab/scanpy")
  end

  def run_worker(ids = ["scanpy"])
    SyncBiotoolsWorker.perform_async(ids)
    SyncBiotoolsWorker.perform_one
  end

  def expire_records
    clear_biotools_jobs
    ExternalSoftwareRecord.update_all(next_refresh_at: 1.minute.ago)
  end

  test "worker retains scientific metadata and matches aliases without changing projects or scores" do
    before = @project.attributes
    request = biotools_record("scanpy")
    run_worker(["SCANPY", "scanpy"])
    record = @project.external_software_records.sole
    assert_equal "biotools", record.source
    assert_equal "scanpy", record.identifier
    assert_equal @biotools["scanpy"], record.metadata
    assert_equal "ok", record.status
    assert_equal "https://bio.tools/scanpy", record.record_url
    assert record.next_refresh_at > 29.days.from_now
    link = @project.project_external_software_records.sole
    assert_equal "repository_alias", link.evidence.sole["match_method"]
    assert_equal "matched", link.match_status
    assert_equal before, @project.reload.attributes
    run_worker
    assert_requested request, times: 1
    assert_equal 1, ExternalSoftwareRecord.count
  end

  test "multiple links to one project count once and shared aliases retain ambiguity" do
    other = Project.create!(url: "https://github.com/other/scanpy", science_score: 42)
    other.repository_aliases.create!(url: "https://github.com/theislab/scanpy")
    @biotools["scanpy"]["link"] << { "url" => @project.url, "type" => ["Repository"] }
    biotools_record("scanpy")
    run_worker
    assert_equal 1, ExternalSoftwareRecord.count
    assert_equal 2, ProjectExternalSoftwareRecord.count
    assert_equal ["ambiguous"], ProjectExternalSoftwareRecord.distinct.pluck(:match_status)
    assert_empty @project.project_external_software_records.registry_references
    assert_empty ProjectExternalSoftwareRecord.scientific_source_counts
  end

  test "homepages documentation downloads and related tools do not establish repository identity" do
    @biotools["scanpy"]["homepage"] = @project.url
    @biotools["scanpy"]["link"] = [{ "url" => @project.url, "type" => ["Helpdesk"] },
      { "url" => "https://user:secret@github.com/scverse/scanpy", "type" => ["Repository"] }]
    @biotools["scanpy"]["download"] = [{ "url" => @project.url, "type" => "Source code" }]
    biotools_record("scanpy")
    run_worker
    assert_empty ProjectExternalSoftwareRecord.all
    assert_equal "ok", ExternalSoftwareRecord.sole.status
  end

  test "refresh removes withdrawn links and never creates projects" do
    biotools_record("scanpy")
    run_worker
    expire_records
    @biotools["scanpy"]["link"] = [{ "url" => "https://github.com/new/repository", "type" => ["Repository"] }]
    biotools_record("scanpy")
    assert_no_difference "Project.count" do
      run_worker
    end
    assert_empty @project.project_external_software_records
    assert_equal "ok", ExternalSoftwareRecord.sole.status
  end

  test "missing responses preserve evidence but hide the withdrawn registry reference" do
    biotools_record("scanpy")
    run_worker
    before = ExternalSoftwareRecord.sole.attributes
    expire_records
    biotools_record("scanpy", payload: {}, status: 404)
    run_worker
    record = ExternalSoftwareRecord.sole
    assert_equal "missing", record.status
    assert_equal before["metadata"], record.metadata
    assert_equal before["retrieved_at"], record.retrieved_at
    assert_equal 1, ProjectExternalSoftwareRecord.count
    assert_empty @project.project_external_software_records.registry_references
    assert record.next_refresh_at > 6.days.from_now
  end

  test "malformed or mismatched records and HTTP failures retain the previous successful record" do
    biotools_record("scanpy")
    run_worker
    before = ExternalSoftwareRecord.sole.attributes
    [{}, @biotools["scanpy"].merge("biotoolsID" => "other"), @biotools["scanpy"].except("link")].each do |payload|
      expire_records
      biotools_record("scanpy", payload: payload)
      assert_raises(BiotoolsClient::Error) { run_worker }
      record = ExternalSoftwareRecord.sole
      assert_equal "error", record.status
      assert_equal before["metadata"], record.metadata
      assert_equal before["retrieved_at"], record.retrieved_at
      assert_equal 1, @project.project_external_software_records.registry_references.size
    end
    expire_records
    biotools_record("scanpy", payload: {}, status: 502)
    assert_raises(BiotoolsClient::Error) { run_worker }
    assert_equal "bio.tools HTTP 502", ExternalSoftwareRecord.sole.last_error
  end

  test "rate limits persist earlier successes and share a cooldown across workers" do
    first = biotools_record("scanpy")
    limited = biotools_record("multiqc", payload: {}, status: 429, headers: { "Retry-After" => "600" })
    run_worker(%w[scanpy multiqc])
    assert_equal "ok", ExternalSoftwareRecord.find_by!(identifier: "scanpy").status
    assert_equal "error", ExternalSoftwareRecord.find_by!(identifier: "multiqc").status
    assert_equal 1, SyncBiotoolsWorker.jobs.size
    assert SyncBiotoolsWorker.jobs.first["at"] >= 9.minutes.from_now.to_f
    assert_raises(BiotoolsClient::RateLimited) { BiotoolsClient.new.record("nextflow") }
    assert_requested first, times: 1
    assert_requested limited, times: 1
  end

  test "a batch shares indexed repository reads and unchanged refreshes do not rewrite links" do
    Project.create!(url: "https://github.com/multiqc/multiqc")
    %w[scanpy multiqc].each { |id| biotools_record(id) }
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      run_worker(%w[scanpy multiqc])
    end
    project_reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "projects"') }
    assert_equal 1, project_reads.size
    assert_not_includes project_reads.first, '"projects".*'
    before = @project.project_external_software_records.sole.attributes
    expire_records
    run_worker
    assert_equal before, @project.project_external_software_records.sole.attributes
  end

  test "invalid identifiers fail before requests or persistence" do
    [[], ["../scanpy"], ["."], ["x" * 101], ["scanpy"] * 51].each do |ids|
      assert_raises(ArgumentError) { SyncBiotoolsWorker.new.perform(ids) }
    end
    assert_empty ExternalSoftwareRecord.all
    assert_not_requested :any, /bio.tools/
  end
end
