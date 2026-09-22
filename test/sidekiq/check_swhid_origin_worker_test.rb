require "test_helper"
require_relative "../support/swhid_pipeline"

class CheckSwhidOriginWorkerTest < ActiveSupport::TestCase
  include SwhidPipeline

  ORIGIN = "https://github.com/example/science"
  SNAPSHOT = "a" * 40

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    @project = Project.create!(url: ORIGIN, science_score: 42, repository: { "clone_url" => ORIGIN },
      swhids: { "status" => "success", "origin" => ORIGIN })
  end

  test "worker records an archived snapshot without needing a matching revision" do
    request = visits_request(ORIGIN).to_return(body: [visit].to_json)
    CheckSwhidOriginWorker.perform_async(@project.id)
    CheckSwhidOriginWorker.perform_one

    result = @project.reload.swhids.fetch("origin_archive")
    assert_equal "archived", result["status"]
    assert_equal SNAPSHOT, result.dig("observations", 0, "visit", "snapshot")
    assert_nil @project.swhids["revision"]
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
    assert_not_requested :post, SwhidArchiver::ENDPOINT
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_requested request, times: 1
  end

  test "repository aliases and git URL variants prevent false missing repository results" do
    old = "https://github.com/example/old-name"
    @project.repository_aliases.create!(url: old)
    request = visits_request("#{old}.git").to_return(body: [visit(origin: "#{old}.git")].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    assert_equal "#{old}.git", @project.swhids.dig("origin_archive", "observations", -1, "origin")
    assert_requested request
  end

  test "previous names retain their original case even before alias indexing" do
    @project.update!(repository: { "previous_names" => ["OldOwner/OldName"] })
    old = "https://github.com/OldOwner/OldName"
    request = visits_request(old).to_return(body: [visit(origin: old)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    assert_requested request
  end

  test "a new alias invalidates a cached negative result" do
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_equal "not_found", @project.reload.swhids.dig("origin_archive", "status")
    old = "https://github.com/example/old-name"
    @project.repository_aliases.create!(url: old)
    visits_request(old).to_return(body: [visit(origin: old)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
  end

  test "failed visits without snapshots do not count as archived" do
    visits_request(ORIGIN).to_return(body: [visit.merge("snapshot" => nil, "status" => "failed")].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "not_found", @project.reload.swhids.dig("origin_archive", "status")
  end

  test "HTTP failures and malformed responses remain unknown" do
    ["not json", { error: "bad" }.to_json, [visit.merge("snapshot" => nil)].to_json,
      [visit.merge("date" => "bad")].to_json, [visit(origin: "https://github.com/wrong/repository")].to_json].each do |body|
      @project.update!(swhids: { "status" => "success", "origin" => ORIGIN })
      visits_request(ORIGIN).to_return(body: body)
      CheckSwhidOriginWorker.new.perform(@project.id)
      assert_equal "unknown", @project.reload.swhids.dig("origin_archive", "status"), body
    end
    @project.update!(swhids: { "status" => "success", "origin" => ORIGIN })
    request = visits_request(ORIGIN).to_return(status: 503)
    CheckSwhidOriginWorker.new.perform(@project.id)
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_equal "unknown", @project.reload.swhids.dig("origin_archive", "status")
    assert_requested request, times: 6
  end

  test "rate limits retain identifiers and respect the shared cooldown" do
    request = visits_request(ORIGIN).to_return(status: 429, headers: { "Retry-After" => "3600" })
    original = @project.swhids.deep_dup
    CheckSwhidOriginWorker.perform_async(@project.id)
    CheckSwhidOriginWorker.perform_one

    assert_equal original, @project.reload.swhids.except("origin_archive")
    assert_equal "unknown", @project.swhids.dig("origin_archive", "status")
    assert_equal 1, CheckSwhidOriginWorker.jobs.size
    assert_operator CheckSwhidOriginWorker.jobs.first["at"], :>, 1.hour.from_now.to_f
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_requested request, times: 1

    travel 2.hours do
      visits_request(ORIGIN).to_return(body: [visit].to_json)
      CheckSwhidOriginWorker.perform_one
      assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
      assert_nil @project.swhids.dig("origin_archive", "retry_at")
    end
  end

  test "historical requests use dated snapshots from paginated visits" do
    cutoff = 10.days.ago.iso8601
    request = { "id" => 123, "attempted_at" => cutoff, "status" => "completed", "confirmed_swhids" => ["test"] }
    @project.update!(swhids: @project.swhids.merge("archival" => request))
    visits_request(ORIGIN).to_return(body: [visit(date: 1.day.ago.iso8601)].to_json,
      headers: { "Link" => "<#{visits_url(ORIGIN)}?last_visit=2&per_page=100>; rel=\"next\"" })
    older = visits_request(ORIGIN, last_visit: "2").to_return(body: [visit(date: 20.days.ago.iso8601, number: 1)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    saved = @project.reload.swhids.fetch("archival")
    assert_equal request, saved.except("repository_before_request")
    assert_equal "missing_versions", saved.dig("repository_before_request", "classification")
    assert_equal "visit_history", saved.dig("repository_before_request", "basis")
    assert_equal cutoff, saved.dig("repository_before_request", "cutoff")
    assert_requested older
  end

  test "a snapshot after submission does not establish earlier coverage or absence" do
    @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 123, "attempted_at" => 10.days.ago.iso8601 }))
    visits_request(ORIGIN).to_return(body: [visit(date: 1.day.ago.iso8601)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    assert_nil @project.swhids.dig("archival", "repository_before_request")
  end

  test "absence today does not classify an old request as a missing repository" do
    @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 123, "attempted_at" => 10.days.ago.iso8601 }))

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "not_found", @project.reload.swhids.dig("origin_archive", "status")
    assert_nil @project.swhids.dig("archival", "repository_before_request")
  end

  test "bounded history and alias checks cannot produce false negative coverage" do
    visits_request(ORIGIN).to_return(body: [visit.merge("status" => "failed", "snapshot" => nil)].to_json,
      headers: { "Link" => "<#{visits_url(ORIGIN)}?last_visit=2>; rel=\"next\"" })
    page = visits_request(ORIGIN, last_visit: "2").to_return(body: [].to_json,
      headers: { "Link" => "<#{visits_url(ORIGIN)}?last_visit=2>; rel=\"next\"" })

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "unknown", @project.reload.swhids.dig("origin_archive", "status")
    assert_requested page, times: 2
    @project.update!(swhids: { "status" => "success", "origin" => ORIGIN }, repository: {
      "previous_names" => (1..10).map { |n| "example/alias-#{n}" }
    })
    visits_request(ORIGIN).to_return(status: 404)
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_equal "unknown", @project.reload.swhids.dig("origin_archive", "status")
    assert_equal SwhidOriginChecker::MAX_ORIGINS, @project.swhids.dig("origin_archive", "observations").size
  end

  test "pagination cannot send the API token to another host" do
    visits_request(ORIGIN).to_return(body: [].to_json, headers: { "Link" => '<https://example.org/steal?last_visit=1>; rel="next"' })

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal "unknown", @project.reload.swhids.dig("origin_archive", "status")
    assert_not_requested :get, /example\.org/
  end

  test "concurrent request changes prevent attaching historical evidence to a different submission" do
    @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 123, "attempted_at" => 1.day.ago.iso8601 }))
    visits_request(ORIGIN).to_return do
      @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 456, "attempted_at" => Time.current.iso8601 }))
      { body: [visit].to_json }
    end

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal 456, @project.reload.swhids.dig("archival", "id")
    assert_nil @project.swhids.dig("archival", "repository_before_request")
  end

  test "ineligible projects are skipped and unscanned projects can still get origin coverage" do
    @project.update!(science_score: 0)
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_not_requested :get, /archive\.softwareheritage\.org/
    @project.update!(science_score: 42, swhids: nil)
    ProjectSwhidScanner.expects(:new).never
    visits_request(ORIGIN).to_return(body: [visit].to_json)
    CheckSwhidOriginWorker.new.perform(@project.id)
    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    assert @project.swhid_scan_due?
    assert_nil @project.swhids["status"]
  end

  if ENV["SWH_LIVE_TEST"] == "true"
    test "live origin history records orbdot coverage without submitting anything" do
      origin = "https://github.com/simonehagey/orbdot"
      @project.update!(url: origin, repository: { "clone_url" => origin }, swhids: { "status" => "success", "origin" => origin })
      remove_request_stub(@origin_stub)
      WebMock.disable_net_connect!(allow: "archive.softwareheritage.org", allow_localhost: true)

      CheckSwhidOriginWorker.perform_async(@project.id)
      CheckSwhidOriginWorker.perform_one

      coverage = @project.reload.swhids.fetch("origin_archive")
      assert_equal "archived", coverage["status"], coverage.inspect
      assert_match(/\A[0-9a-f]{40}\z/, coverage.dig("observations", 0, "visit", "snapshot"))
      assert_not_requested :post, /archive\.softwareheritage\.org/
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  def visits_url(origin)
    "#{SwhidOriginChecker::ENDPOINT}#{ERB::Util.url_encode(origin)}/visits/"
  end

  def visits_request(origin, **params)
    stub_request(:get, visits_url(origin)).with(query: { "per_page" => "100" }.merge(params.transform_keys(&:to_s)))
  end

  def visit(origin: ORIGIN, date: 30.days.ago.iso8601, number: 2)
    { "origin" => origin, "date" => date, "visit" => number, "snapshot" => SNAPSHOT, "type" => "git", "status" => "full" }
  end
end
