require "test_helper"
require "rake"
require_relative "../support/rrid_pipeline"

class ImportRridSeedsWorkerTest < ActiveSupport::TestCase
  include RridPipeline

  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("rrid:seed") }

  def invoke_task(name, **env)
    previous = env.to_h { |key, value| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def cached_tool(id, identifiers)
    ExternalSoftwareRecord.create!(source: "biotools", identifier: id, status: "ok", retrieved_at: Time.current,
      next_refresh_at: 30.days.from_now, metadata: { "otherID" => identifiers })
  end

  test "rake seed pages cached bio.tools records and refresh imports deduplicated software IDs" do
    cached_tool("a", [{ "type" => "rrid", "value" => "RRID:SCR_015687" }])
    cached_tool("b", [{ "type" => "RRID", "value" => "scr_015687" }, { "type" => "doi", "value" => "SCR_026162" }])
    cached_tool("c", [{ "type" => "rrid", "value" => "SCR_026162" }, { "type" => "rrid", "value" => "AB_123456" }])
    project = Project.create!(url: "https://github.com/mikelove/deseq2")
    assert_equal 2, JSON.parse(invoke_task("rrid:seed", LIMIT: 2))["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "rrid_seeds")
    ImportRridSeedsWorker.perform_one
    assert_equal "b", import.reload.cursor
    assert_equal 2, import.items_processed
    assert_equal ["SCR_015687"], ExternalSoftwareRecord.where(source: "rrid").pluck(:identifier)
    travel_to import.next_run_at + 1.second
    ImportRridSeedsWorker.perform_one
    assert import.reload.completed_at
    assert_equal 3, import.items_processed
    %w[SCR_015687 SCR_026162].each { |id| rrid_record(id) }
    assert_equal 2, JSON.parse(invoke_task("rrid:refresh"))["queued"]
    SyncRridWorker.perform_one
    assert_equal "SCR_015687", project.external_software_records.sole.identifier
    assert_equal true, JSON.parse(invoke_task("rrid:status"))["complete"]
    assert_equal false, JSON.parse(invoke_task("rrid:resume"))["queued"]
    invoke_task("rrid:rescan")
    ImportRridSeedsWorker.perform_one
    assert_equal 0, JSON.parse(invoke_task("rrid:refresh"))["queued"]
    assert_equal 2, ExternalSoftwareRecord.where(source: "rrid").count
  end

  test "saved seed pages resume after failure and only scanned source rows advance the cursor" do
    cached_tool("deseq2", [{ "type" => "rrid", "value" => "SCR_015687" }])
    invoke_task("rrid:seed")
    RridSeeds.stubs(:persist).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportRridSeedsWorker.perform_one }
    RridSeeds.unstub(:persist)
    import = ExternalSoftwareImport.find_by!(source: "rrid_seeds")
    assert_equal 1, import.pending_records.size
    assert_nil import.cursor
    assert_nil import.lease_token
    assert_equal 0, import.items_processed
    RridSeeds.expects(:page).never
    travel_to import.next_run_at + 1.second do
      invoke_task("rrid:resume")
      ImportRridSeedsWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal "deseq2", import.cursor
    assert_equal 1, ExternalSoftwareRecord.where(source: "rrid").count
  end

  test "seed insert and cursor advancement roll back together" do
    cached_tool("deseq2", [{ "type" => "rrid", "value" => "SCR_015687" }])
    invoke_task("rrid:seed")
    ExternalSoftwareImport.any_instance.stubs(:advance_catalogue).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportRridSeedsWorker.perform_one }
    assert_empty ExternalSoftwareRecord.where(source: "rrid")
    import = ExternalSoftwareImport.find_by!(source: "rrid_seeds")
    assert_equal 1, import.pending_records.size
    assert_equal 0, import.items_processed
  end

  test "schedules never initiate seeding and leases prevent overlapping work" do
    assert_equal false, JSON.parse(invoke_task("rrid:rescan"))["queued"]
    assert_equal false, JSON.parse(invoke_task("rrid:resume"))["queued"]
    assert_raises(ArgumentError) { invoke_task("rrid:seed", LIMIT: 51) }
    invoke_task("rrid:seed", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "rrid_seeds")
    assert_raises(ArgumentError) { invoke_task("rrid:seed", RESTART: true) }
    assert_raises(ArgumentError) { invoke_task("rrid:seed", LIMIT: 3) }
    token = import.claim
    assert_nil import.claim
    assert_nil import.advance_catalogue("wrong-token")
    RridSeeds.expects(:page).never
    ImportRridSeedsWorker.new.perform(import.id)
    import.defer(token, Time.current, "retry")
    assert_nil import.reload.lease_token
  end

  test "manual imports and refresh bound requests to the due RRID population" do
    rrid_record("SCR_015687")
    assert_equal 1, JSON.parse(invoke_task("rrid:import", IDS: "RRID:SCR_015687,scr_015687"))["queued"]
    SyncRridWorker.perform_one
    expire_rrid
    ExternalSoftwareRecord.create!(source: "rrid", identifier: "SCR_026162", next_refresh_at: 1.day.ago)
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "1010.083", next_refresh_at: 2.days.ago)
    assert_equal 1, JSON.parse(invoke_task("rrid:refresh", LIMIT: 1))["queued"]
    assert_equal [["SCR_026162"]], SyncRridWorker.jobs.map { |job| job["args"].first }
    assert_raises(ArgumentError) { invoke_task("rrid:refresh", LIMIT: 1001) }
  end

  test "seeding reads only identifier fields from retrieved bio.tools records and preserves fresh RRIDs" do
    entries = [{ "type" => "rrid", "value" => "SCR_015687" }, nil, { "type" => "rrid", "value" => "SCR_123" }]
    cached_tool("a", entries)
    cached_tool("b", entries).update!(status: "error")
    cached_tool("missing", [{ "type" => "rrid", "value" => "SCR_026162" }]).update!(status: "missing")
    cached_tool("pending", [{ "type" => "rrid", "value" => "SCR_026162" }]).update!(retrieved_at: nil)
    fresh = ExternalSoftwareRecord.create!(source: "rrid", identifier: "SCR_015687", status: "ok",
      retrieved_at: Time.current, next_refresh_at: 30.days.from_now, metadata: @rrid["SCR_015687"])
    before = fresh.attributes
    invoke_task("rrid:seed")
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      ImportRridSeedsWorker.perform_one
    end
    assert_equal before, fresh.reload.attributes
    assert_equal 1, ExternalSoftwareRecord.where(source: "rrid").count
    assert_equal 2, ExternalSoftwareImport.find_by!(source: "rrid_seeds").items_processed
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('"external_software_records"') }
    assert_equal 1, reads.size
    assert_includes reads.sole, "metadata -> 'otherID'"
    refute_includes reads.sole, '"external_software_records"."metadata"'
    assert_not_requested :any, /scicrunch.org/
  end
end
