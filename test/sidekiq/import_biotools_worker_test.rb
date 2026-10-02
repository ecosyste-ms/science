require "test_helper"
require "rake"
require_relative "../support/biotools_pipeline"

class ImportBiotoolsWorkerTest < ActiveSupport::TestCase
  include BiotoolsPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("biotools:sweep")
    @env = ENV.to_h.slice("LIMIT", "RESTART", "IDS")
    %w[LIMIT RESTART IDS].each { |key| ENV.delete(key) }
  end

  teardown do
    %w[LIMIT RESTART IDS].each { |key| ENV.delete(key) }
    ENV.update(@env)
  end

  def task(name)
    Rake::Task["biotools:#{name}"].reenable
    output, = capture_io { Rake::Task["biotools:#{name}"].invoke }
    JSON.parse(output)
  end

  def start_sweep
    ENV["LIMIT"] = "2"
    task("sweep")
    ENV.delete("LIMIT")
    ExternalSoftwareImport.find_by!(source: "biotools")
  end

  def perform_next
    job = ImportBiotoolsWorker.jobs.first
    assert job, "expected a continuation job"
    travel_to(Time.at([job["at"] || Time.current.to_f, Time.current.to_f].max) + 1.second) do
      ImportBiotoolsWorker.perform_one
    end
  end

  test "task processes full page metadata through persisted matches and completion without detail requests" do
    project = Project.create!(url: "https://github.com/multiqc/multiqc", science_score: 42)
    before = project.attributes
    first = biotools_page(1, %w[multiqc scanpy], next_page: 2)
    last = biotools_page(2, %w[nextflow biopython])
    import = start_sweep
    perform_next
    assert_equal "2", import.reload.cursor
    assert_equal 2, import.items_processed
    assert_empty import.pending_records
    assert_nil import.page_retrieved_at
    perform_next
    assert import.reload.completed_at
    assert_equal 4, import.items_processed
    assert_equal 2, import.pages_processed
    assert_empty ImportBiotoolsWorker.jobs
    assert_equal "multiqc", project.external_software_records.sole.identifier
    assert_equal @biotools["multiqc"], project.external_software_records.sole.metadata
    assert_equal before, project.reload.attributes
    assert_requested first, times: 1
    assert_requested last, times: 1
    assert_not_requested :get, %r{/api/tool/[^/?]+/}
    assert_equal true, task("status")["complete"]
  end

  test "interrupted saved pages resume without fetching changed pagination" do
    first = biotools_page(1, %w[multiqc scanpy])
    import = start_sweep
    BiotoolsImporter.any_instance.stubs(:sync_page).raises(Interrupt)
    assert_raises(Interrupt) { perform_next }
    BiotoolsImporter.any_instance.unstub(:sync_page)
    assert_equal %w[multiqc scanpy], import.reload.pending_ids
    assert_equal 2, import.pending_records.size
    assert_equal false, task("resume")["queued"]
    travel_to(import.lease_expires_at + 1.second) do
      assert_equal true, task("resume")["queued"]
      ImportBiotoolsWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 2, ExternalSoftwareRecord.count
    assert_requested first, times: 1
  end

  test "stale page data cannot overwrite a newer manual refresh" do
    biotools_page(1, %w[scanpy])
    newer = @biotools["scanpy"].merge("name" => "Newer Scanpy")
    ExternalSoftwareRecord.create!(source: "biotools", identifier: "scanpy", status: "ok", metadata: newer,
      retrieved_at: 1.day.from_now, attempted_at: 1.day.from_now, next_refresh_at: 31.days.from_now)
    import = start_sweep
    perform_next
    assert import.reload.completed_at
    assert_equal newer, ExternalSoftwareRecord.sole.metadata
  end

  test "duplicate jobs cannot claim an active lease or advance another worker's lease" do
    import = start_sweep
    task("sweep")
    token = import.claim
    perform_next
    assert_equal token, import.reload.lease_token
    assert_not_requested :any, /bio.tools/
    biotools_page(1, [])
    travel_to(import.lease_expires_at + 1.second) do
      ImportBiotoolsWorker.perform_one
    end
    assert import.reload.completed_at
    assert_nil import.advance_catalogue(token)
    assert_equal 1, import.pages_processed
  end

  test "rate limits and invalid pagination preserve the cursor and schedule bounded retries" do
    biotools_page(1, [], status: 429, headers: { "Retry-After" => "600" })
    import = start_sweep
    perform_next
    assert_equal "1", import.reload.cursor
    assert_nil import.lease_token
    assert import.next_run_at >= 9.minutes.from_now
    assert_equal false, task("resume")["queued"]
    biotools_page(1, %w[scanpy], next_page: 1)
    perform_next
    assert_equal "Invalid bio.tools next page", import.reload.last_error
    assert_equal 0, import.items_processed
    assert_empty ExternalSoftwareRecord.all
  end

  test "duplicate or malformed entities cannot advance the page" do
    import = start_sweep
    biotools_page(1, %w[scanpy scanpy])
    perform_next
    assert_equal "Duplicate bio.tools page identifiers", import.reload.last_error
    @biotools["scanpy"].delete("link")
    biotools_page(1, %w[scanpy])
    perform_next
    assert_equal "Invalid bio.tools page", import.reload.last_error
    assert_equal "1", import.cursor
    assert_empty ExternalSoftwareRecord.all
  end

  test "scheduling failure after checkpoint retains committed progress for recovery" do
    biotools_page(1, %w[scanpy], next_page: 2)
    import = start_sweep
    ImportBiotoolsWorker.stubs(:perform_at).raises(RuntimeError, "queue unavailable")
    assert_raises(RuntimeError) { perform_next }
    ImportBiotoolsWorker.unstub(:perform_at)
    assert_equal "2", import.reload.cursor
    assert_nil import.lease_token
    biotools_page(2, [])
    travel_to(import.next_run_at + 1.second) do
      task("resume")
      ImportBiotoolsWorker.perform_one
    end
    assert import.reload.completed_at
  end

  test "recovery does not start imports and completed sweeps require an explicit restart" do
    assert_equal({ "status" => "not_started" }, task("status"))
    assert_equal({ "queued" => false }, task("resume"))
    import = start_sweep
    ENV["RESTART"] = "true"
    assert_raises(ArgumentError) { task("sweep") }
    ENV.delete("RESTART")
    biotools_page(1, [])
    perform_next
    task("sweep")
    assert_empty ImportBiotoolsWorker.jobs
    ENV["RESTART"] = "true"
    task("sweep")
    assert_nil import.reload.completed_at
    assert_equal "1", import.cursor
    assert_equal 0, import.pages_processed
  end

  test "refresh selects only bounded due bio.tools records and manual import canonicalizes IDs" do
    %w[scanpy multiqc].each do |id|
      ExternalSoftwareRecord.create!(source: "biotools", identifier: id, next_refresh_at: 1.hour.ago)
    end
    ExternalSoftwareRecord.create!(source: "biotools", identifier: "nextflow", next_refresh_at: 1.day.from_now)
    ExternalSoftwareRecord.create!(source: "wikidata", identifier: "Q1", next_refresh_at: 1.day.ago)
    ENV["LIMIT"] = "1"
    assert_equal({ "queued" => 1 }, task("refresh"))
    assert_equal [["scanpy"]], SyncBiotoolsWorker.jobs.map { |job| job["args"].sole }
    clear_biotools_jobs
    ENV["IDS"] = "SCANPY,scanpy,multiqc"
    assert_equal({ "queued" => 2 }, task("import"))
    assert_equal [["scanpy", "multiqc"]], SyncBiotoolsWorker.jobs.map { |job| job["args"].sole }
    ENV["LIMIT"] = "1001"
    assert_raises(ArgumentError) { task("refresh") }
    ENV["LIMIT"] = "51"
    assert_raises(ArgumentError) { task("sweep") }
  end
end
