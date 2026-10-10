require "test_helper"
require "rake"
require "shellwords"
require_relative "../support/biotools_pipeline"

class ExternalSoftwareResweepTest < ActiveSupport::TestCase
  include BiotoolsPipeline

  WORKERS = { "wikidata" => ImportWikidataWorker, "biotools" => ImportBiotoolsWorker,
    "ascl" => ImportAsclWorker, "swmath" => ImportSwmathWorker, "rrid" => ImportRridWorker }.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wikidata:resweep")
    WORKERS.each_value(&:clear)
  end

  teardown { WORKERS.each_value(&:clear) }

  def scheduled_task(source)
    cron = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .select { |entry| entry.fetch("command").include?("#{source}:resweep") }.sole
    commands = Shellwords.split(cron.fetch("command"))
    assert_equal %w[bundle exec rake], commands.first(3)
    output, = capture_io do
      commands.drop(3).each do |name|
        Rake::Task[name].reenable
        Rake::Task[name].invoke
      end
    end
    JSON.parse(output)
  end

  def start_import(source)
    if source == "wikidata"
      ExternalSoftwareImport.start_wikidata(page_size: 2)
    else
      ExternalSoftwareImport.start_catalogue(source: source, page_size: 2)
    end
  end

  test "weekly schedules use distinct weekdays and do not enable new sources" do
    crons = JSON.parse(Rails.root.join("app.json").read).fetch("cron")
      .select { |entry| entry.fetch("command").include?(":resweep") }
    assert_equal WORKERS.keys.map { |source| "bundle exec rake #{source}:resweep" }, crons.pluck("command")
    assert_equal (1..5).map { |day| "20 4 * * #{day}" }, crons.pluck("schedule")
    WORKERS.each do |source, worker|
      assert_equal({ "queued" => false }, scheduled_task(source))
      assert_empty worker.jobs
    end
    assert_empty ExternalSoftwareImport.all
  end

  test "completed catalogues restart from the beginning with the saved batch size" do
    WORKERS.each do |source, worker|
      import = start_import(source)
      import.update!(cursor: "old-cursor", completed_at: 1.day.ago, started_at: 8.days.ago,
        pages_processed: 3, items_processed: 5, last_error: "previous error")
      assert_equal({ "queued" => true }, scheduled_task(source))
      import.reload
      assert_nil import.completed_at
      if source == "biotools"
        assert_equal "1", import.cursor
      else
        assert_nil import.cursor
      end
      assert_equal 2, import.page_size
      assert_equal 0, import.items_processed
      assert_equal 0, import.pages_processed
      assert_nil import.last_error
      assert import.started_at > 1.minute.ago
      assert_equal [[import.id]], worker.jobs.pluck("args")
    end
  end

  test "unfinished catalogues retain saved pages leases and retry times" do
    WORKERS.each do |source, worker|
      import = start_import(source)
      import.update!(cursor: "saved-cursor", pages_processed: 2, items_processed: 4,
        pending_ids: ["saved-id"], pending_records: [{ "id" => "saved-id" }],
        pending_next_cursor: "next-cursor", page_retrieved_at: 1.minute.ago,
        next_run_at: 1.hour.from_now, lease_token: "active-lease", lease_expires_at: 10.minutes.from_now,
        last_error: "rate limited")
      before = import.attributes
      2.times { assert_equal({ "queued" => true }, scheduled_task(source)) }
      assert_equal before, import.reload.attributes
      assert_equal [[import.id], [import.id]], worker.jobs.pluck("args")
      worker.jobs.each { |job| assert_in_delta import.next_run_at.to_f, job.fetch("at"), 1 }
    end
  end

  test "a queue failure leaves the restarted sweep available to recovery" do
    import = start_import("biotools")
    import.update!(completed_at: 1.day.ago)
    ImportBiotoolsWorker.stubs(:perform_at).raises(RedisClient::CannotConnectError)
    assert_raises(RedisClient::CannotConnectError) { scheduled_task("biotools") }
    assert_nil import.reload.completed_at
    ImportBiotoolsWorker.unstub(:perform_at)
    Rake::Task["biotools:resume"].reenable
    capture_io { Rake::Task["biotools:resume"].invoke }
    assert_equal [[import.id]], ImportBiotoolsWorker.jobs.pluck("args")
  end

  test "weekly task imports newly added records through the catalogue worker" do
    import = start_import("biotools")
    biotools_page(1, %w[scanpy])
    import.enqueue
    ImportBiotoolsWorker.perform_one
    assert import.reload.completed_at
    project = Project.create!(url: "https://github.com/multiqc/multiqc", science_score: 0)

    travel 7.days do
      biotools_page(1, %w[multiqc scanpy], next_page: 2)
      biotools_page(2, %w[nextflow])
      scheduled_task("biotools")
      ImportBiotoolsWorker.perform_one
      assert_equal "2", import.reload.cursor
      assert_equal 2, import.items_processed
      travel_to(import.next_run_at + 1.second)
      ImportBiotoolsWorker.perform_one
      assert import.reload.completed_at
      assert_equal 3, import.items_processed
      assert_equal %w[multiqc nextflow scanpy], ExternalSoftwareRecord.order(:identifier).pluck(:identifier)
      assert_equal "multiqc", project.external_software_records.sole.identifier
      assert_equal @biotools["multiqc"], project.external_software_records.sole.metadata
      assert_equal 0, project.reload.science_score
    end
  end
end
