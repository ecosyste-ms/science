require "test_helper"
require "rake"
require "tempfile"
require_relative "../support/mloss_pipeline"

class JournalAssociationReviewRakeTest < ActiveSupport::TestCase
  include MlossPipeline

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("journals:audit")
    @project = Project.create!(url: "https://github.com/neuraloperator/neuraloperator")
    mloss_catalogue
    Rake::Task["mloss:sweep"].reenable
    capture_io { Rake::Task["mloss:sweep"].invoke }
    ImportMlossWorker.perform_one
  end

  def audit(source: nil, after: nil, limit: 50)
    before = ENV.to_h.slice("OUTPUT", "SOURCE", "AFTER", "LIMIT")
    Tempfile.create(["journal-associations", ".json"]) do |output|
      ENV.update("OUTPUT" => output.path, "SOURCE" => source, "AFTER" => after&.to_s, "LIMIT" => limit.to_s)
      Rake::Task["journals:audit"].reenable
      counts = [Project.count, Paper.count, ExternalSoftwareRecord.count, ProjectExternalSoftwareRecord.count]
      jobs = Sidekiq::Worker.jobs.deep_dup
      capture_io { Rake::Task["journals:audit"].invoke }
      assert_equal counts, [Project.count, Paper.count, ExternalSoftwareRecord.count, ProjectExternalSoftwareRecord.count]
      assert_equal jobs, Sidekiq::Worker.jobs
      JSON.parse(File.read(output.path))
    end
  ensure
    %w[OUTPUT SOURCE AFTER LIMIT].each { |key| ENV[key] = before[key] }
  end

  test "review reports existing enrichment new discovery and unresolved URLs without network access" do
    DiscoverExternalRepositoriesWorker.new.perform(10)
    WebMock.reset!
    report = audit
    assert_equal 5, report["summary"]["records"]
    assert_equal 2, report["summary"]["matched_projects"]
    assert_equal 1, report["summary"]["projects_created_by_these_records"]
    assert_equal 1, report["summary"]["other_matched_projects"]
    assert_equal 3, report["summary"]["records_with_unresolved_code"]
    existing = report["records"].find { |row| row["identifier"] == "v27/26-0434" }
    assert_equal @project.url, existing["project_candidates"].sole["url"]
    assert_equal false, existing["project_candidates"].sole["created_by_record"]
    owner = report["records"].find { |row| row["identifier"] == "v25/24-0110" }
    assert_equal ["https://github.com/pyt-team"], owner["unresolved_code_urls"]
    assert_not_requested :any, /jmlr.org/
  end

  test "pagination and source filtering bound review output" do
    seen = []
    after = nil
    loop do
      report = audit(source: "MLOSS", after: after, limit: 2)
      assert_operator report["records"].size, :<=, 2
      seen.concat(report["records"].pluck("record_id"))
      after = report["next_after"]
      break unless after
    end
    assert_equal 5, seen.uniq.size
    assert_equal 5, seen.size
    assert_empty audit(source: "jss")["records"]
    assert_raises(ArgumentError) { audit(source: "anything") }
    assert_raises(ArgumentError) { audit(limit: 101) }
  end

  test "ambiguous candidates remain visible to review without counting as matches" do
    other = Project.create!(url: "https://github.com/other/neuraloperator")
    other.repository_aliases.create!(url: @project.url)
    expire_mloss
    SyncMlossWorker.new.perform(["v27/26-0434"])
    report = audit
    assert_equal 2, report["summary"]["ambiguous_candidates"]
    row = report["records"].find { |item| item["identifier"] == "v27/26-0434" }
    assert_equal [@project.url], row["unresolved_code_urls"]
    assert_equal 0, report["summary"]["matched_projects"]
  end

  test "owners hidden after import are excluded from matched project counts" do
    host = Host.find_or_create_by!(name: "GitHub", url: "https://github.com")
    owner = Owner.create!(host: host, login: "neuraloperator")
    @project.update!(owner_record: owner)
    owner.update!(hidden: true)
    report = audit
    assert_equal 1, report["summary"]["hidden_candidates"]
    assert_equal 0, report["summary"]["matched_projects"]
    row = report["records"].find { |item| item["identifier"] == "v27/26-0434" }
    assert_equal true, row["project_candidates"].sole["hidden"]
    assert_equal [@project.url], row["unresolved_code_urls"]
  end
end
