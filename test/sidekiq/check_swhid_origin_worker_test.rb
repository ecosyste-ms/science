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

  test "worker keeps the latest failed attempt separate from an older snapshot" do
    snapshot = visit(date: 30.days.ago.iso8601, number: 1)
    failed = visit(date: 1.day.ago.iso8601, number: 2).merge("status" => "failed", "snapshot" => nil)
    visits_request(ORIGIN).to_return(body: [failed, snapshot].to_json)

    CheckSwhidOriginWorker.perform_async(@project.id)
    CheckSwhidOriginWorker.perform_one

    coverage = @project.reload.swhids.fetch("origin_archive")
    observation = coverage["observations"].first
    assert_equal "archived", coverage["status"]
    assert_equal failed.slice("origin", "date", "visit", "snapshot", "status", "type"), observation["latest_attempt"]
    assert_equal snapshot["date"], observation.dig("visit", "date")
    assert_equal ORIGIN, observation.dig("visit", "origin")
    assert_equal "current", observation["origin_role"]
    assert_equal [ORIGIN, "#{ORIGIN}.git"], coverage["current_origins"]
    assert_equal true, observation["freshness_complete"]
    assert_equal false, coverage["freshness_complete"]
    assert_equal ["#{ORIGIN}.git"], coverage["unchecked_origins"]
  end

  test "a former origin snapshot does not establish current repository freshness" do
    former = "https://github.com/example/former"
    @project.update!(swhids: { "status" => "success", "origin" => former })
    visits_request(former).to_return(body: [visit(origin: former, date: 1.hour.ago.iso8601)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal "archived", coverage["status"]
    assert_equal "other", coverage.dig("observations", 0, "origin_role")
    assert_equal SNAPSHOT, coverage.dig("observations", 0, "visit", "snapshot")
    assert_includes coverage["unchecked_origins"], ORIGIN
    assert_equal [ORIGIN, "#{ORIGIN}.git"], coverage["current_origins"]
    assert_equal false, coverage["freshness_complete"]
  end

  test "freshness runs continue through remaining aliases in bounded batches" do
    @project.update!(repository: { "previous_names" => (1..5).map { |n| "example/alias-#{n}" } })
    origins = SwhidOriginChecker.new(@project).origins
    requests = origins.map do |origin|
      visits_request(origin).to_return(body: [visit(origin: origin)].to_json)
    end
    CheckSwhidOriginWorker.new.perform(@project.id)
    initial = @project.reload.swhids.dig("origin_archive", "observations", 0)

    CheckSwhidOriginWorker.perform_async(@project.id, false, true)
    CheckSwhidOriginWorker.perform_one
    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal 9, coverage["observations"].length
    assert_equal false, coverage["freshness_complete"]
    assert_equal origins.drop(9), coverage["unchecked_origins"]
    assert coverage["freshness_retry_at"]
    CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    assert_requested :get, /archive\.softwareheritage\.org/, times: 9

    travel 2.hours do
      CheckSwhidOriginWorker.perform_async(@project.id, false, true)
      CheckSwhidOriginWorker.perform_one
    end

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal true, coverage["freshness_complete"]
    assert_equal initial, coverage["observations"].first
    assert_nil coverage["freshness_retry_at"]
    assert_empty coverage["unchecked_origins"]
    requests.each { |request| assert_requested request, times: 1 }
    assert_not_requested :post, /archive\.softwareheritage\.org/
  end

  test "unread history leaves snapshot freshness incomplete while retaining the newest attempt" do
    failed = visit(date: 1.day.ago.iso8601, number: 4).merge("status" => "ongoing", "snapshot" => nil)
    first = visits_request(ORIGIN).to_return(body: [failed].to_json, headers: next_visit_headers(3))
    visits_request(ORIGIN, last_visit: "3").to_return(body: [].to_json, headers: next_visit_headers(2))
    visits_request(ORIGIN, last_visit: "2").to_return(body: [].to_json, headers: next_visit_headers(1))
    visits_request(ORIGIN, last_visit: "1").to_return(body: [visit(number: 1)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    initial = @project.reload.swhids.dig("origin_archive", "observations", 0)
    assert_equal "ongoing", initial.dig("latest_attempt", "status")
    assert_equal false, initial["freshness_complete"]
    assert_equal false, initial["history_complete"]
    assert_equal "1", initial["next_visit"]
    assert_nil initial["visit"]

    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    end

    coverage = @project.reload.swhids.fetch("origin_archive")
    observation = coverage["observations"].first
    assert_equal initial["latest_attempt"], observation["latest_attempt"]
    assert_equal initial["latest_attempt_checked_at"], observation["latest_attempt_checked_at"]
    assert_equal true, observation["freshness_complete"]
    assert_equal true, coverage["freshness_complete"]
    assert_equal SNAPSHOT, observation.dig("visit", "snapshot")
    assert_requested first, times: 1
  end

  test "newest snapshot can be established without exhausting older visit history" do
    visits_request(ORIGIN).to_return(body: [visit].to_json, headers: next_visit_headers(1))

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal true, coverage["freshness_complete"]
    assert_equal true, coverage.dig("observations", 0, "freshness_complete")
    assert_equal false, coverage.dig("observations", 0, "history_complete")
    assert_not_requested :get, visits_url(ORIGIN), query: { per_page: 100, last_visit: "1" }
  end

  test "freshness retries preserve their mode and completed observations after a rate limit" do
    visits_request(ORIGIN).to_return(body: [visit].to_json)
    other = "#{ORIGIN}.git"
    visits_request(other).to_return(status: 429, headers: { "Retry-After" => "3600" })

    CheckSwhidOriginWorker.perform_async(@project.id, false, true)
    CheckSwhidOriginWorker.perform_one
    initial = @project.reload.swhids.dig("origin_archive", "observations", 0)
    assert_equal [[@project.id, false, true]], CheckSwhidOriginWorker.jobs.pluck("args")
    assert @project.swhids.dig("origin_archive", "freshness_retry_at")

    travel 2.hours do
      visits_request(other).to_return(status: 404)
      CheckSwhidOriginWorker.perform_one
    end

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal initial, coverage["observations"].first
    assert_equal true, coverage["freshness_complete"]
    assert_nil coverage["freshness_retry_at"]
    assert_nil coverage["retry_at"]
  end

  test "failed freshness refresh preserves visit evidence and its observation date" do
    request = visits_request(ORIGIN).to_return(body: [visit].to_json)
    CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    initial = @project.reload.swhids.dig("origin_archive", "observations", 0)
    travel 8.days do
      visits_request(ORIGIN).to_return(status: 503)
      CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    end

    coverage = @project.reload.swhids.fetch("origin_archive")
    observation = coverage["observations"].first
    assert_equal initial["latest_attempt"], observation["latest_attempt"]
    assert_equal initial["latest_attempt_checked_at"], observation["latest_attempt_checked_at"]
    assert_equal initial["visit"], observation["visit"]
    assert_equal false, observation["freshness_complete"]
    assert_equal false, coverage["freshness_complete"]
    assert_requested request, times: 2
  end

  test "current URL roles preserve path case on other forges" do
    current = "https://forge.example/Group/Repo"
    @project.update_columns(url: current, repository: { "clone_url" => "#{current}.git" },
      swhids: { "origin" => current })
    visits_request(current).to_return(body: [visit(origin: current)].to_json)
    visits_request(current.downcase).to_return(body: [visit(origin: current.downcase)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal current, coverage["repository_url"]
    assert_equal [current, "#{current}.git"], coverage["current_origins"]
    roles = coverage["observations"].to_h { |entry| [entry["origin"], entry["origin_role"]] }
    assert_equal "current", roles[current]
    assert_equal "other", roles[current.downcase]
  end

  test "freshness initializes legacy coverage and restarts history without a first-page observation" do
    @project.update!(swhids: @project.swhids.merge("origin_archive" => {
      "status" => "archived", "checked_at" => Time.current.iso8601,
      "origins" => [ORIGIN, "#{ORIGIN}.git"],
      "observations" => [{ "origin" => ORIGIN, "status" => "archived", "lookup_complete" => false,
        "visit" => visit.except("origin"), "next_visit" => "1" }]
    }))
    recent = visit(date: 1.day.ago.iso8601).merge("status" => "failed", "snapshot" => nil)
    first = visits_request(ORIGIN).to_return(body: [recent, visit].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)

    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal true, coverage["freshness_complete"]
    assert_equal "failed", coverage.dig("observations", 0, "latest_attempt", "status")
    assert_requested first, times: 1
    assert_not_requested :get, visits_url(ORIGIN), query: { per_page: 100, last_visit: "1" }
  end

  test "refresh observes an ongoing visit becoming complete without changing its date" do
    ongoing = visit(date: 1.day.ago.iso8601, number: 4).merge("status" => "ongoing", "snapshot" => nil)
    visits_request(ORIGIN).to_return(body: [ongoing, visit(number: 1)].to_json)
    CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    travel 8.days do
      visits_request(ORIGIN).to_return(body: [ongoing.merge("status" => "full", "snapshot" => SNAPSHOT)].to_json)
      CheckSwhidOriginWorker.new.perform(@project.id, false, true)
    end

    observation = @project.reload.swhids.dig("origin_archive", "observations", 0)
    assert_equal "full", observation.dig("latest_attempt", "status")
    assert_equal ongoing["date"], observation.dig("latest_attempt", "date")
    assert_equal ongoing["date"], observation.dig("visit", "date")
  end

  test "freshness refresh preserves known pre-submission classification" do
    baseline = { "classification" => "missing_repository", "basis" => "pre_submission", "checked_at" => 1.year.ago.iso8601 }
    @project.update!(swhids: @project.swhids.merge("archival" => {
      "id" => 123, "attempted_at" => 1.year.ago.iso8601, "repository_before_request" => baseline
    }))
    visits_request(ORIGIN).to_return(body: [visit].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)

    assert_equal baseline, @project.reload.swhids.dig("archival", "repository_before_request")
    assert_equal "archived", @project.swhids.dig("origin_archive", "status")
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

  test "later runs reach the ninth candidate without repeating completed lookups" do
    @project.update!(repository: { "previous_names" => (1..5).map { |n| "example/alias-#{n}" } })
    origins = SwhidOriginChecker.new(@project).origins
    first = visits_request(origins.first).to_return(status: 404)
    ninth = visits_request(origins.fetch(8)).to_return(body: [visit(origin: origins.fetch(8))].to_json)

    CheckSwhidOriginWorker.perform_async(@project.id)
    CheckSwhidOriginWorker.perform_one
    initial = @project.reload.swhids.fetch("origin_archive")
    assert_equal "unknown", initial["status"]
    assert_equal origins.drop(8), initial["unchecked_origins"]
    assert_equal false, initial["complete"]

    travel 2.hours do
      CheckSwhidOriginWorker.perform_async(@project.id)
      CheckSwhidOriginWorker.perform_one
    end

    saved = @project.reload.swhids.fetch("origin_archive")
    assert_equal "archived", saved["status"]
    assert_equal initial["observations"].first, saved["observations"].first
    assert_equal origins.drop(9), saved["unchecked_origins"]
    assert_requested first, times: 1
    assert_requested ninth, times: 1
  end

  test "untried candidates precede repeated inconclusive results" do
    @project.update!(repository: { "previous_names" => (1..5).map { |n| "example/alias-#{n}" } })
    origins = SwhidOriginChecker.new(@project).origins
    failures = origins.first(8).map { |origin| visits_request(origin).to_return(status: 503) }
    ninth = visits_request(origins.fetch(8)).to_return(body: [visit(origin: origins.fetch(8))].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)
    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id)
    end

    assert_equal "archived", @project.reload.swhids.dig("origin_archive", "status")
    failures.each { |request| assert_requested request, times: 1 }
    assert_requested ninth, times: 1
  end

  test "history resumes at the saved page after reaching the page limit" do
    first = visits_request(ORIGIN).to_return(body: [].to_json, headers: next_visit_headers(2))
    second = visits_request(ORIGIN, last_visit: "2").to_return(body: [].to_json, headers: next_visit_headers(3))
    third = visits_request(ORIGIN, last_visit: "3").to_return(body: [].to_json, headers: next_visit_headers(4))
    last = visits_request(ORIGIN, last_visit: "4").to_return(body: [visit].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)
    saved = @project.reload.swhids.dig("origin_archive", "observations", 0)
    assert_equal "4", saved["next_visit"]
    assert_equal false, saved["lookup_complete"]
    assert_equal false, saved["history_complete"]
    assert_nil saved["checked_at"]

    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id)
    end

    saved = @project.reload.swhids.dig("origin_archive", "observations", 0)
    assert_equal "archived", saved["status"]
    assert_equal true, saved["lookup_complete"]
    assert_equal true, saved["history_complete"]
    assert_nil saved["next_visit"]
    [first, second, third, last].each { |request| assert_requested request, times: 1 }
  end

  test "request limit preserves the cursor and leaves later candidates unchecked" do
    @project.update!(repository: { "previous_names" => ["example/old", "example/older"] })
    origins = SwhidOriginChecker.new(@project).origins
    origins.first(4).each do |origin|
      visits_request(origin).to_return(body: [].to_json, headers: next_visit_headers(2, origin: origin))
      visits_request(origin, last_visit: "2").to_return(body: [].to_json, headers: next_visit_headers(3, origin: origin))
      visits_request(origin, last_visit: "3").to_return(body: [].to_json, headers: next_visit_headers(4, origin: origin))
      visits_request(origin, last_visit: "4").to_return(body: [].to_json)
    end

    CheckSwhidOriginWorker.new.perform(@project.id)
    saved = @project.reload.swhids.fetch("origin_archive")
    assert_equal "2", saved["observations"].last["next_visit"]
    assert_equal origins.drop(4), saved["unchecked_origins"]
    assert_equal "unknown", saved["status"]
    assert_requested :get, /archive\.softwareheritage\.org/, times: SwhidOriginChecker::MAX_REQUESTS

    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id)
    end
    saved = @project.reload.swhids.fetch("origin_archive")
    assert_equal "not_found", saved["status"]
    assert_equal true, saved["complete"]
    assert_empty saved["unchecked_origins"]
    origins.first(4).each { |origin| assert_requested visits_request(origin), times: 1 }
  end

  test "rate limits preserve completed origins and the interrupted history cursor" do
    first = visits_request(ORIGIN).to_return(status: 404)
    other = "#{ORIGIN}.git"
    page = visits_request(other).to_return(body: [].to_json, headers: next_visit_headers(2, origin: other))
    last = visits_request(other, last_visit: "2").to_return(status: 429, headers: { "Retry-After" => "3600" })

    CheckSwhidOriginWorker.perform_async(@project.id)
    CheckSwhidOriginWorker.perform_one
    saved = @project.reload.swhids.fetch("origin_archive")
    original = saved["observations"].first.deep_dup
    assert_equal "not_found", original["status"]
    assert_equal "2", saved["observations"].last["next_visit"]
    assert_equal false, saved["complete"]

    travel 2.hours do
      visits_request(other, last_visit: "2").to_return(body: [visit(origin: other)].to_json)
      CheckSwhidOriginWorker.perform_one
    end

    saved = @project.reload.swhids.fetch("origin_archive")
    assert_equal "archived", saved["status"]
    assert_equal original, saved["observations"].first
    assert_requested first, times: 1
    assert_requested page, times: 1
    assert_requested last, times: 2
  end

  test "candidate changes preserve retained URLs and discard removed URLs" do
    old = "https://github.com/OldOwner/OldName"
    @project.update!(repository: { "previous_names" => [old] })
    CheckSwhidOriginWorker.new.perform(@project.id)
    original = @project.reload.swhids.dig("origin_archive", "observations", 0).deep_dup
    first = visits_request(ORIGIN).to_return(status: 404)

    travel 2.hours do
      @project.update!(repository: { "previous_names" => ["NewOwner/NewName"] })
      new_origin = "https://github.com/NewOwner/NewName"
      request = visits_request(new_origin).to_return(body: [visit(origin: new_origin)].to_json)
      CheckSwhidOriginWorker.new.perform(@project.id)
      assert_requested request, times: 1
    end

    saved = @project.reload.swhids.fetch("origin_archive")
    assert_equal original, saved["observations"].first
    assert_not_includes saved["observations"].pluck("origin"), old
    assert_requested first, times: 1
  end

  test "stale observations refresh without losing archived evidence on failure" do
    request = visits_request(ORIGIN).to_return(body: [visit].to_json)
    CheckSwhidOriginWorker.new.perform(@project.id)
    original = @project.reload.swhids.dig("origin_archive", "observations", 0).deep_dup

    travel 8.days do
      visits_request(ORIGIN).to_return(status: 503)
      CheckSwhidOriginWorker.new.perform(@project.id)
      saved = @project.reload.swhids.dig("origin_archive", "observations", 0)
      assert_equal original["visit"], saved["visit"]
      assert_equal original["checked_at"], saved["checked_at"]
      assert_equal "archived", saved["status"]
      assert_equal false, saved["lookup_complete"]
      assert_equal "HTTP 503", saved["error"]
    end
    assert_requested request, times: 2
  end

  test "stale negative observations refresh across bounded runs" do
    @project.update!(repository: { "previous_names" => (1..5).map { |n| "example/alias-#{n}" } })
    origins = SwhidOriginChecker.new(@project).origins
    CheckSwhidOriginWorker.new.perform(@project.id)
    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id)
    end
    assert_equal "not_found", @project.reload.swhids.dig("origin_archive", "status")

    travel 8.days do
      CheckSwhidOriginWorker.new.perform(@project.id)
      coverage = @project.reload.swhids.fetch("origin_archive")
      assert_equal "unknown", SwhidOriginChecker.before_submission(coverage)["classification"]
      ninth = visits_request(origins.fetch(8)).to_return(body: [visit(origin: origins.fetch(8))].to_json)
      CheckSwhidOriginWorker.new.perform(@project.id)
      assert_requested ninth, times: 2
      coverage = @project.reload.swhids.fetch("origin_archive")
      assert_equal "archived", coverage["status"]
      assert_equal "missing_versions", SwhidOriginChecker.before_submission(coverage)["classification"]
    end
  end

  test "historical snapshot searches resume while retaining current coverage" do
    cutoff = 10.days.ago.iso8601
    @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 123, "attempted_at" => cutoff }))
    first = visits_request(ORIGIN).to_return(body: [visit(date: 1.day.ago.iso8601)].to_json, headers: next_visit_headers(2))
    visits_request(ORIGIN, last_visit: "2").to_return(body: [].to_json, headers: next_visit_headers(3))
    visits_request(ORIGIN, last_visit: "3").to_return(body: [].to_json, headers: next_visit_headers(4))
    last = visits_request(ORIGIN, last_visit: "4").to_return(body: [visit(date: 20.days.ago.iso8601)].to_json)

    CheckSwhidOriginWorker.new.perform(@project.id)
    coverage = @project.reload.swhids.fetch("origin_archive")
    assert_equal "archived", coverage["status"]
    assert_equal false, coverage["complete"]
    assert_equal cutoff, coverage["observations"].first["history_cutoff"]
    assert coverage["retry_at"]
    assert_nil @project.swhids.dig("archival", "repository_before_request")

    travel 2.hours do
      CheckSwhidOriginWorker.new.perform(@project.id)
    end

    assert_equal "missing_versions", @project.reload.swhids.dig("archival", "repository_before_request", "classification")
    assert_requested first, times: 1
    assert_requested last, times: 1
  end

  test "a changed submission cutoff restarts history without reusing prior evidence" do
    @project.update!(swhids: @project.swhids.merge("archival" => { "id" => 123, "attempted_at" => 10.days.ago.iso8601 }))
    visits_request(ORIGIN).to_return(body: [visit(date: 1.day.ago.iso8601)].to_json, headers: next_visit_headers(2))
    visits_request(ORIGIN, last_visit: "2").to_return(body: [].to_json, headers: next_visit_headers(3))
    visits_request(ORIGIN, last_visit: "3").to_return(body: [].to_json, headers: next_visit_headers(4))
    CheckSwhidOriginWorker.new.perform(@project.id)

    travel 2.hours do
      @project.reload.update!(swhids: @project.swhids.merge("archival" => { "id" => 456, "attempted_at" => 40.days.ago.iso8601 }))
      first = visits_request(ORIGIN).to_return(body: [visit(date: 20.days.ago.iso8601)].to_json)
      CheckSwhidOriginWorker.new.perform(@project.id)
      assert_requested first, times: 2
    end

    saved = @project.reload.swhids
    assert_nil saved.dig("archival", "repository_before_request")
    assert_equal true, saved.dig("origin_archive", "observations", 0, "history_complete")
    assert_nil saved.dig("origin_archive", "observations", 0, "next_visit")
  end

  test "concurrent coverage updates are not overwritten" do
    newer = { "status" => "archived", "checked_at" => Time.current.iso8601, "observations" => [] }
    visits_request(ORIGIN).to_return do
      @project.update!(swhids: @project.swhids.merge("origin_archive" => newer))
      { status: 404 }
    end

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_equal newer, @project.reload.swhids["origin_archive"]
  end

  test "concurrent candidate changes leave saved coverage untouched" do
    visits_request(ORIGIN).to_return do
      @project.update!(repository: { "previous_names" => ["example/added"] })
      { status: 404 }
    end

    CheckSwhidOriginWorker.new.perform(@project.id)

    assert_nil @project.reload.swhids["origin_archive"]
  end

  test "concurrent current URL changes cannot store roles for the previous URL" do
    visits_request(ORIGIN).to_return do
      @project.update_columns(url: "#{ORIGIN}.git")
      { body: [visit].to_json }
    end

    CheckSwhidOriginWorker.new.perform(@project.id, false, true)

    assert_nil @project.reload.swhids["origin_archive"]
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

      CheckSwhidOriginWorker.perform_async(@project.id, false, true)
      CheckSwhidOriginWorker.perform_one

      coverage = @project.reload.swhids.fetch("origin_archive")
      assert_equal "archived", coverage["status"], coverage.inspect
      assert_match(/\A[0-9a-f]{40}\z/, coverage.dig("observations", 0, "visit", "snapshot"))
      assert_equal origin, coverage.dig("observations", 0, "latest_attempt", "origin")
      assert_equal "current", coverage.dig("observations", 0, "origin_role")
      assert_equal true, coverage["freshness_complete"], coverage.inspect
      assert_empty coverage["unchecked_origins"]
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

  def next_visit_headers(cursor, origin: ORIGIN)
    { "Link" => "<#{visits_url(origin)}?last_visit=#{cursor}>; rel=\"next\"" }
  end

  def visit(origin: ORIGIN, date: 30.days.ago.iso8601, number: 2)
    { "origin" => origin, "date" => date, "visit" => number, "snapshot" => SNAPSHOT, "type" => "git", "status" => "full" }
  end
end
