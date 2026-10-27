require "test_helper"
require "rake"
require_relative "../support/journal_schedule"
require_relative "../support/mloss_pipeline"

class JournalSchedulingTest < ActiveSupport::TestCase
  include JournalSchedule
  include MlossPipeline

  WORKERS = { "mloss" => ImportMlossWorker, "jors" => ImportJournalWorker, "jss" => ImportJournalWorker }.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("mloss:harvest")
    [ImportJournalWorker, SyncJournalWorker, DiscoverExternalRepositoriesWorker].each(&:clear)
  end

  teardown { [ImportJournalWorker, SyncJournalWorker, DiscoverExternalRepositoriesWorker].each(&:clear) }

  test "scheduled harvests bootstrap all three journals without a manual sweep" do
    WORKERS.each do |source, worker|
      progress = scheduled_journal_tasks(source, "harvest").sole
      import = ExternalSoftwareImport.find_by!(source: source)
      assert_equal source, progress.fetch("source")
      assert_equal false, progress.fetch("complete")
      assert_equal source == "mloss" ? 50 : 5, import.page_size
      assert_equal [import.id], worker.jobs.last.fetch("args")
    end
    assert_nil JSON.parse(ExternalSoftwareImport.find_by!(source: "jss").cursor)["from"]
    assert_equal 3, ExternalSoftwareImport.count
    assert_not_requested :any, /https?:/
  end

  test "scheduled harvests restart completed catalogues and advance the JSS date window" do
    WORKERS.each_key { |source| scheduled_journal_tasks(source, "harvest") }
    previous_until = JSON.parse(ExternalSoftwareImport.find_by!(source: "jss").cursor).fetch("until")
    ExternalSoftwareImport.update_all(completed_at: Time.current, page_size: 2, pages_processed: 3, items_processed: 6)
    travel 1.day do
      WORKERS.each do |source, worker|
        worker.clear
        scheduled_journal_tasks(source, "harvest")
        import = ExternalSoftwareImport.find_by!(source: source)
        assert_nil import.completed_at
        assert_equal 2, import.page_size
        assert_equal 0, import.items_processed
        assert_equal 0, import.pages_processed
        if source == "jss"
          assert_equal previous_until, JSON.parse(import.cursor).fetch("from")
          assert_equal Time.current.utc.iso8601, JSON.parse(import.cursor).fetch("until")
        else
          assert_nil import.cursor
        end
        assert_equal [[import.id]], worker.jobs.pluck("args")
      end
    end
  end

  test "harvest and recovery preserve saved pages and respect leases and retry times" do
    WORKERS.each do |source, worker|
      scheduled_journal_tasks(source, "harvest")
      import = ExternalSoftwareImport.find_by!(source: source)
      import.update!(pending_ids: ["saved-id"], pending_records: [{ "id" => "saved-id" }],
        page_retrieved_at: 1.minute.ago, next_run_at: 1.hour.from_now,
        lease_token: "active", lease_expires_at: 10.minutes.from_now, last_error: "rate limited")
      before = import.attributes
      worker.clear
      scheduled_journal_tasks(source, "harvest")
      assert_equal before, import.reload.attributes
      assert_in_delta import.next_run_at.to_f, worker.jobs.sole.fetch("at"), 1
      worker.clear
      assert_equal [{ "queued" => false }, { "queued" => 0 }], scheduled_journal_tasks(source, "resume")
      assert_empty worker.jobs
      travel_to import.next_run_at + 1.second do
        assert_equal [{ "queued" => true }, { "queued" => 0 }], scheduled_journal_tasks(source, "resume")
        assert_equal [[import.id]], worker.jobs.pluck("args")
        assert_equal before, import.reload.attributes
      end
    end
  end

  test "recovery queues only due refresh records including failed pilot imports" do
    { "mloss" => "v27/26-0434", "jors" => "10.5334/jors.359", "jss" => "oai:ojs.pkp.sfu.ca:article/5712" }.each do |source, id|
      worker = source == "mloss" ? SyncMlossWorker : SyncJournalWorker
      worker.clear
      record = ExternalSoftwareRecord.create!(source: source, identifier: id, status: "error",
        next_refresh_at: 1.hour.from_now, last_error: "timeout")
      assert_equal [{ "queued" => false }, { "queued" => 0 }], scheduled_journal_tasks(source, "resume")
      assert_empty worker.jobs
      travel_to record.next_refresh_at + 1.second do
        assert_equal [{ "queued" => false }, { "queued" => 1 }], scheduled_journal_tasks(source, "resume")
        assert_equal source == "mloss" ? [[id]] : [source, [id]], worker.jobs.sole.fetch("args")
      end
    end
    assert_empty ExternalSoftwareImport.all
  end

  test "queue failures leave initial harvests available to the scheduled recovery" do
    ImportJournalWorker.stubs(:perform_at).raises(RedisClient::CannotConnectError)
    assert_raises(RedisClient::CannotConnectError) { scheduled_journal_tasks("jss", "harvest") }
    import = ExternalSoftwareImport.find_by!(source: "jss")
    assert_nil import.completed_at
    ImportJournalWorker.unstub(:perform_at)
    scheduled_journal_tasks("jss", "resume")
    assert_equal [[import.id]], ImportJournalWorker.jobs.pluck("args")
  end

  test "weekly harvest updates publications and discovery follows a changed repository" do
    project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator")
    mloss_catalogue
    scheduled_journal_tasks("mloss", "harvest")
    ImportMlossWorker.perform_one
    paper = project.project_papers.sole.paper
    original_count = Paper.count

    travel 7.days do
      updated = @mloss_html.gsub(project.url, "https://github.com/neuraloperator/new-repository")
        .gsub("A Library for Learning Neural Operators", "Updated Neural Operators")
      mloss_catalogue(body: updated)
      scheduled_journal_tasks("mloss", "harvest")
      ImportMlossWorker.perform_one
      assert_equal "Updated Neural Operators", paper.reload.title
      assert_equal original_count, Paper.count
      assert_empty project.project_papers
      scheduled_journal_tasks("external_software", "discover")
      DiscoverExternalRepositoriesWorker.perform_one
      scheduled_journal_tasks("external_software", "sync")
      replacement = Project.find_by!(url: "https://github.com/neuraloperator/new-repository")
      assert_equal paper.id, replacement.project_papers.sole.paper_id
      assert_equal "software_description", replacement.project_papers.sole.role
      request = ExternalProjectSync.find_by!(project_id: replacement.id)
      assert SyncExternalProjectWorker.jobs.any? { |job| job.fetch("args").first == request.id }
    end
  end
end
