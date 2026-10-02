require "test_helper"
require "rake"
require_relative "../support/software_doi_pipeline"

class ImportSoftwareDoiSeedsWorkerTest < ActiveSupport::TestCase
  include SoftwareDoiPipeline

  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("software_dois:seed") }

  def invoke_task(name, **env)
    previous = env.to_h { |key, value| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "rake seed scans bounded project pages and refresh matches known DOIs once" do
    id = "10.6084/m9.figshare.9577868"
    first = doi_project(doi: id)
    second = doi_project(url: "https://github.com/example/codemeta", codemeta: { identifier: id, referencePublication: "10.1234/paper" }.to_json)
    last = doi_project(url: "https://github.com/example/zenodo", zenodo: { doi: "10.5281/zenodo.15878535" }.to_json)
    doi_project(url: "https://github.com/example/low", doi: "10.1234/low", science_score: 1)
    doi_project(url: "https://github.com/example/hidden", doi: "10.1234/hidden", hidden: true)
    assert_equal 2, JSON.parse(invoke_task("software_dois:seed", LIMIT: 2))["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "doi_seeds")
    ImportSoftwareDoiSeedsWorker.perform_one
    assert_equal second.id.to_s, import.reload.cursor
    assert_equal 2, import.items_processed
    assert_equal [id], ExternalSoftwareRecord.where(source: "doi").pluck(:identifier)
    travel_to import.next_run_at + 1.second
    ImportSoftwareDoiSeedsWorker.perform_one
    assert import.reload.completed_at
    assert_equal last.id.to_s, import.cursor
    assert_equal 3, import.items_processed
    [id, "10.5281/zenodo.15878535"].each { |doi| doi_record(doi) }
    assert_equal 2, JSON.parse(invoke_task("software_dois:refresh"))["queued"]
    SyncSoftwareDoiWorker.perform_one
    assert_equal id, first.external_software_records.sole.identifier
    assert_equal true, JSON.parse(invoke_task("software_dois:status"))["complete"]
    assert_equal false, JSON.parse(invoke_task("software_dois:resume"))["queued"]
    before = ExternalSoftwareRecord.order(:id).map(&:attributes)
    invoke_task("software_dois:rescan")
    ImportSoftwareDoiSeedsWorker.perform_one
    assert_equal 0, JSON.parse(invoke_task("software_dois:refresh"))["queued"]
    assert_equal before, ExternalSoftwareRecord.order(:id).map(&:attributes)
  end

  test "saved pages recover failures without rescanning and cursor advances atomically" do
    doi_project(doi: "10.6084/m9.figshare.9577868")
    invoke_task("software_dois:seed")
    ExternalSoftwareImport.any_instance.stubs(:advance_catalogue).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportSoftwareDoiSeedsWorker.perform_one }
    assert_empty ExternalSoftwareRecord.where(source: "doi")
    import = ExternalSoftwareImport.find_by!(source: "doi_seeds")
    assert_equal 1, import.pending_records.size
    assert_equal 0, import.items_processed
    assert_nil import.cursor
    assert_nil import.lease_token
    ExternalSoftwareImport.any_instance.unstub(:advance_catalogue)
    SoftwareDoiSeeds.expects(:page).never
    travel_to import.next_run_at + 1.second do
      invoke_task("software_dois:resume")
      ImportSoftwareDoiSeedsWorker.perform_one
    end
    assert import.reload.completed_at
    assert_equal 1, ExternalSoftwareRecord.where(source: "doi").count
  end

  test "cron never starts a seed pass and leases prevent duplicate page work" do
    assert_equal false, JSON.parse(invoke_task("software_dois:rescan"))["queued"]
    assert_equal false, JSON.parse(invoke_task("software_dois:resume"))["queued"]
    assert_raises(ArgumentError) { invoke_task("software_dois:seed", LIMIT: 26) }
    invoke_task("software_dois:seed", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "doi_seeds")
    assert_raises(ArgumentError) { invoke_task("software_dois:seed", RESTART: true) }
    assert_raises(ArgumentError) { invoke_task("software_dois:seed", LIMIT: 3) }
    token = import.claim
    assert_nil import.claim
    assert_nil import.advance_catalogue("wrong-token")
    SoftwareDoiSeeds.expects(:page).never
    ImportSoftwareDoiSeedsWorker.new.perform(import.id)
    import.defer(token, Time.current, "retry")
    commands = JSON.parse(Rails.root.join("app.json").read)["cron"].pluck("command")
    assert_includes commands, "bundle exec rake software_dois:resume software_dois:refresh"
    assert_includes commands, "bundle exec rake software_dois:rescan"
  end

  test "manual import and refresh limit requests to the due DOI population" do
    id = "10.6084/m9.figshare.9577868"
    datacite_record(id)
    assert_equal 1, JSON.parse(invoke_task("software_dois:import", IDS: "doi:#{id},#{id.upcase}"))["queued"]
    SyncSoftwareDoiWorker.perform_one
    expire_dois
    ExternalSoftwareRecord.create!(source: "doi", identifier: "10.5281/zenodo.15878535", next_refresh_at: 1.day.ago)
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "1010.083", next_refresh_at: 2.days.ago)
    assert_equal 1, JSON.parse(invoke_task("software_dois:refresh", LIMIT: 1))["queued"]
    assert_equal [["10.5281/zenodo.15878535"]], SyncSoftwareDoiWorker.jobs.map { |job| job["args"].first }
    assert_raises(ArgumentError) { invoke_task("software_dois:refresh", LIMIT: 1001) }
  end

  test "scan selects only citation metadata through the DOI partial index predicate" do
    doi_project(doi: "10.6084/m9.figshare.9577868")
    invoke_task("software_dois:seed", LIMIT: 1)
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      ImportSoftwareDoiSeedsWorker.perform_one
    end
    reads = queries.select { |sql| sql.start_with?("SELECT") && sql.include?('FROM "projects"') }
    assert_equal 1, reads.size
    assert_includes reads.sole, "search_identifiers ? 'doi'"
    assert_includes reads.sole, '"projects"."citation_file"'
    assert_includes reads.sole, 'LIMIT'
    refute_includes reads.sole, '"projects"."repository"'
    refute_includes reads.sole, '"projects".*'
    assert_not_requested :any, /datacite.org|zenodo.org/
  end
end
