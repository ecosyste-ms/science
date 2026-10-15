require "test_helper"
require "rake"
require_relative "../support/mloss_pipeline"

class ImportMlossWorkerTest < ActiveSupport::TestCase
  include MlossPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("mloss:sweep")
    @project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator", science_score: 42)
  end

  def invoke_task(name, **env)
    previous = env.to_h { |key, _| [key.to_s, ENV[key.to_s]] }
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "rake sweep resumes bounded pages and retains DOI-less article identity and unresolved code links" do
    request = mloss_catalogue
    output = JSON.parse(invoke_task("mloss:sweep", LIMIT: 2))
    assert_equal 2, output["page_size"]
    import = ExternalSoftwareImport.find_by!(source: "mloss")
    ImportMlossWorker.perform_one
    assert_equal 2, import.reload.items_processed
    assert_nil import.completed_at
    2.times do
      travel_to import.next_run_at + 1.second do
        ImportMlossWorker.perform_one
      end
      import.reload
    end
    assert import.completed_at
    assert_equal 5, import.items_processed
    assert_equal 3, import.pages_processed
    assert_equal 5, ExternalSoftwareRecord.count
    record = @project.external_software_records.sole
    assert_equal "v27/26-0434", record.identifier
    assert_equal "https://www.jmlr.org/papers/v27/26-0434.html", record.record_url
    assert_equal "A Library for Learning Neural Operators", record.metadata["title"]
    assert_equal [@project.url], record.metadata["code_urls"]
    assert_equal MlossClient::CATALOGUE_URL, record.collection_url
    assert ExternalSoftwareRecord.all.any? { |r| r.metadata["code_urls"] == ["https://github.com/pyt-team"] && r.projects.empty? }
    assert_equal 42, @project.reload.science_score
    assert_equal 5, Paper.count
    assert_equal 5, PaperIdentifier.count
    assert_nil @project.project_papers.sole.paper.doi
    assert_empty @project.project_external_software_records.confirmed_identifier_matches
    assert_requested request, times: 1
    assert_equal true, JSON.parse(invoke_task("mloss:status"))["complete"]
    assert_equal false, JSON.parse(invoke_task("mloss:resume"))["queued"]
  end

  test "saved pages survive interrupted matching without another source request" do
    mloss_catalogue
    invoke_task("mloss:sweep", LIMIT: 2)
    MlossImporter.any_instance.stubs(:sync_page).raises(RuntimeError, "interrupted")
    assert_raises(RuntimeError) { ImportMlossWorker.perform_one }
    import = ExternalSoftwareImport.find_by!(source: "mloss")
    assert_equal 2, import.pending_records.size
    assert_equal 0, import.items_processed
    assert_nil import.cursor
    assert_nil import.lease_token
    MlossImporter.any_instance.unstub(:sync_page)
    Rails.cache.delete(MlossClient::CACHE_KEY)
    WebMock.reset!
    travel_to import.next_run_at + 1.second do
      invoke_task("mloss:resume")
      ImportMlossWorker.perform_one
    end
    assert_equal 2, import.reload.items_processed
    assert_equal 2, ExternalSoftwareRecord.count
    assert_not_requested :any, /jmlr.org/
  end

  test "resweeps require an enabled import and repeat completed catalogues" do
    assert_equal false, JSON.parse(invoke_task("mloss:resweep"))["queued"]
    assert_equal false, JSON.parse(invoke_task("mloss:resume"))["queued"]
    mloss_catalogue
    invoke_task("mloss:sweep")
    import = ExternalSoftwareImport.find_by!(source: "mloss")
    assert_raises(ArgumentError) { invoke_task("mloss:sweep", RESTART: true) }
    assert_raises(ArgumentError) { invoke_task("mloss:sweep", LIMIT: 2) }
    ImportMlossWorker.perform_one
    assert import.reload.completed_at
    assert_equal true, JSON.parse(invoke_task("mloss:resweep"))["queued"]
    assert_nil import.reload.completed_at
    assert_nil import.cursor
    assert_equal 0, import.items_processed
    ImportMlossWorker.perform_one
    assert_equal 5, ExternalSoftwareRecord.count
  end

  test "rate limits and malformed source pages retain sweep progress" do
    request = mloss_catalogue(status: 429, headers: { "Retry-After" => "600" })
    invoke_task("mloss:sweep", LIMIT: 2)
    import = ExternalSoftwareImport.find_by!(source: "mloss")
    ImportMlossWorker.perform_one
    assert_match "rate limit", import.reload.last_error
    assert import.next_run_at >= 9.minutes.from_now
    assert_equal 0, import.items_processed
    assert_empty import.pending_records
    assert_raises(MlossClient::RateLimited) { MlossClient.new.catalogue }
    assert_requested request, times: 1
    travel_to import.next_run_at + 1.second do
      mloss_catalogue(body: "<html>Unavailable</html>")
      ImportMlossWorker.new.perform(import.id)
    end
    assert_match "heading", import.reload.last_error
    assert_nil import.cursor
    assert_equal 0, import.items_processed
  end

  test "manual imports and bounded refresh select only due MLOSS records" do
    mloss_catalogue
    assert_equal 1, JSON.parse(invoke_task("mloss:import", IDS: "v27/26-0434,v27/26-0434"))["queued"]
    SyncMlossWorker.perform_one
    assert_equal 0, JSON.parse(invoke_task("mloss:refresh"))["queued"]
    expire_mloss
    ExternalSoftwareRecord.create!(source: "mloss", identifier: "v27/25-2553", next_refresh_at: 1.day.ago)
    ExternalSoftwareRecord.create!(source: "ascl", identifier: "1609.011", next_refresh_at: 1.day.ago)
    assert_equal 1, JSON.parse(invoke_task("mloss:refresh", LIMIT: 1))["queued"]
    assert_equal [["v27/25-2553"]], SyncMlossWorker.jobs.map { |job| job["args"].first }
    assert_raises(ArgumentError) { invoke_task("mloss:import", IDS: "../anything") }
    assert_raises(ArgumentError) { invoke_task("mloss:refresh", LIMIT: 1001) }
  end

  test "unresolved report paginates cached owner registry and homepage links without requests" do
    mloss_catalogue
    invoke_task("mloss:sweep")
    ImportMlossWorker.perform_one
    WebMock.reset!
    output = JSON.parse(invoke_task("mloss:unresolved", LIMIT: 2))
    assert_equal 2, output["records"].size
    assert_equal "v25/24-0110", output["next_after"]
    owner = output["records"].find { |row| row["identifier"] == "v25/24-0110" }
    assert_equal ["https://github.com/pyt-team"], owner["code_urls"]
    assert_equal "https://www.jmlr.org/papers/v25/24-0110.html", owner["article_url"]
    output = JSON.parse(invoke_task("mloss:unresolved", AFTER: output["next_after"]))
    assert_equal ["v9/klanke08a"], output["records"].pluck("identifier")
    assert_nil output["next_after"]
    assert_not_requested :any, /jmlr.org/
    assert_raises(ArgumentError) { invoke_task("mloss:unresolved", LIMIT: 51) }
  end

  test "discovery creates repositories from labelled code links and respects hidden owners" do
    hidden = Owner.create!(host: Host.create!(name: "GitHub", url: "https://github.com", kind: "GitHub"), login: "THU-BPM", hidden: true)
    mloss_catalogue
    invoke_task("mloss:sweep")
    ImportMlossWorker.perform_one
    @project.destroy!
    result = nil
    assert_difference "Project.count", 1 do
      result = DiscoverExternalRepositoriesWorker.new.perform(10)
    end
    assert_equal 1, result[:sources]["mloss"]["created"]
    assert_equal 1, result[:sources]["mloss"]["hidden"]
    project = Project.find_by!(url: "https://github.com/neuraloperator/neuraloperator")
    assert_equal "v27/26-0434", project.external_software_records.sole.identifier
    assert_equal "software_description", project.project_papers.sole.role
    assert ExternalProjectSync.exists?(project_id: project.id)
    assert_equal 0, project.science_score.to_f
    assert_empty Project.where(owner_id: hidden.id)
    assert_not Project.exists?(url: "https://github.com/pyt-team")
  end
end
