require "test_helper"
require_relative "../support/swhid_pipeline"

class CheckSwhidBatchWorkerTest < ActiveSupport::TestCase
  include SwhidPipeline

  setup do
    FetchSwhidWorker.jobs.clear
    CheckSwhidArchivalWorker.jobs.clear
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
  end

  teardown do
    FetchSwhidWorker.jobs.clear
    CheckSwhidArchivalWorker.jobs.clear
  end

  test "sync combines projects and duplicate identifiers into one scheduled lookup" do
    first = create_project(1)
    second = create_project(2)
    second.update!(swhids: second.swhids.merge("directory" => first.swhids["directory"]))
    expected = identifiers(first, second).uniq
    request = known_request(expected)

    [first, second, first].each(&:fetch_swhids_async)
    FetchSwhidWorker.drain

    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_equal 2, pending_ids.size
    assert_not_requested request
    CheckSwhidBatchWorker.perform_one

    [first, second].each do |project|
      assert_equal "archived", project.reload.swhids.dig("revision", "archive", "status")
      assert_equal "archived", project.swhids.dig("directory", "archive", "status")
    end
    assert_requested request, times: 1
    assert_empty pending_ids
    assert_empty CheckSwhidBatchWorker.jobs
  end

  test "batches never exceed one thousand identifiers and schedule remaining projects" do
    rows = (1..501).map do |number|
      { url: "https://github.com/batch/project-#{number}", science_score: 42, repository: {}, swhids: data(number) }
    end
    ids = Project.insert_all!(rows, returning: %w[id]).rows.flatten
    ids.each { |id| CheckSwhidBatchWorker.enqueue(id) }
    sizes = []
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return do |request|
      ids = JSON.parse(request.body)
      sizes << ids.size
      { status: 200, body: ids.to_h { |id| [id, { known: true }] }.to_json }
    end

    CheckSwhidBatchWorker.perform_one
    assert_equal [1_000], sizes
    assert_equal 1, pending_ids.size
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    CheckSwhidBatchWorker.perform_one

    assert_equal [1_000, 2], sizes
    assert_requested request, times: 2
    assert_empty pending_ids
  end

  test "rate limits retain the whole batch and schedule one retry" do
    projects = [create_project(1), create_project(2)]
    request = stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(status: 429, headers: { "Retry-After" => "7200" })
    projects.each(&:fetch_swhids_async)
    FetchSwhidWorker.drain
    CheckSwhidBatchWorker.perform_one

    assert_equal projects.map { |p| p.id.to_s }.sort, pending_ids.sort
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    retry_at = CheckSwhidBatchWorker.jobs.first.fetch("at")
    assert_operator retry_at, :>, 2.hours.from_now.to_f
    assert_operator retry_at, :<=, 2.hours.from_now.to_f + 300
    projects.each do |project|
      assert_equal "HTTP 429", project.reload.swhids.dig("revision", "archive", "error")
    end

    third = create_project(3)
    third.fetch_swhids_async
    FetchSwhidWorker.drain
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    assert_requested request, times: 1

    known_request(identifiers(*projects, third))
    travel_to Time.at(retry_at) do
      CheckSwhidBatchWorker.perform_one
      projects.push(third).each do |project|
        assert_equal "archived", project.reload.swhids.dig("revision", "archive", "status")
        assert_nil project.swhids.dig("revision", "archive", "retry_at")
      end
    end
    assert_empty pending_ids
  end

  test "deleted and ineligible projects are removed without checking them" do
    deleted = create_project(1)
    unscientific = create_project(2)
    hidden = create_project(3)
    no_repository = create_project(4)
    [deleted, unscientific, hidden, no_repository].each { |project| CheckSwhidBatchWorker.enqueue(project.id) }
    deleted.destroy!
    unscientific.update!(science_score: 0)
    no_repository.update!(repository: nil)
    owner = Owner.create!(host: Host.create!(name: "GitHub"), login: "batch")
    hidden.update!(owner_record: owner)
    owner.update!(hidden: true)

    CheckSwhidBatchWorker.perform_one

    assert_empty pending_ids
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  end

  test "partial results preserve first observations and do not turn missing responses into missing objects" do
    first = create_project(1)
    second = create_project(2)
    previous = { "known" => false, "checked_at" => 10.days.ago.iso8601 }
    stored = first.swhids.deep_dup
    stored["revision"]["archive"] = { "first_check" => previous }
    first.update!(swhids: stored)
    ids = identifiers(first, second)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { ids[0] => { known: true }, ids[1] => { known: false }, ids[2] => { known: "false" } }.to_json)
    [first, second].each { |project| CheckSwhidBatchWorker.enqueue(project.id) }

    CheckSwhidBatchWorker.perform_one

    assert_equal previous, first.reload.swhids.dig("revision", "archive", "first_check")
    assert_equal "not_found", first.swhids.dig("directory", "archive", "status")
    assert_equal "error", second.reload.swhids.dig("revision", "archive", "status")
    assert_equal "error", second.swhids.dig("directory", "archive", "status")
    assert_equal [[first.id]], CheckSwhidArchivalWorker.jobs.map { |job| job["args"] }
  end

  test "batch responses preserve concurrent archival evidence and newer object checks" do
    project = create_project(1)
    evidence = { "status" => "completed", "confirmed_swhids" => [] }
    newer = { "status" => "not_found", "checked_at" => Time.current.iso8601 }
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).to_return do |request|
      stored = project.reload.swhids.deep_dup
      stored["archival"] = evidence
      stored["revision"]["archive"] = newer
      project.update!(swhids: stored)
      { body: JSON.parse(request.body).to_h { |id| [id, { known: true }] }.to_json }
    end
    CheckSwhidBatchWorker.enqueue(project.id)

    CheckSwhidBatchWorker.perform_one

    assert_equal evidence, project.reload.swhids["archival"]
    assert_equal newer, project.swhids.dig("revision", "archive")
    assert_equal "archived", project.swhids.dig("directory", "archive", "status")
  end

  test "an unexpected failure retains pending work for Sidekiq retry" do
    project = create_project(1)
    CheckSwhidBatchWorker.enqueue(project.id)
    SwhidArchiveChecker.expects(:check_batch).raises(RuntimeError, "interrupted")

    assert_raises(RuntimeError) { CheckSwhidBatchWorker.perform_one }

    assert_equal [project.id.to_s], pending_ids
    assert_empty CheckSwhidBatchWorker.jobs
  end

  test "another batch holding the advisory lock prevents overlapping lookups" do
    project = create_project(1)
    CheckSwhidBatchWorker.enqueue(project.id)
    connection = PG.connect(Project.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    assert_equal Project.connection_db_config.database, connection.db
    connection.exec("SELECT pg_advisory_lock(#{CheckSwhidBatchWorker::ADVISORY_LOCK})")

    CheckSwhidBatchWorker.perform_one

    assert_equal [project.id.to_s], pending_ids
    assert_not_requested :post, SwhidArchiveChecker::ENDPOINT
  ensure
    if connection
      connection.exec("SELECT pg_advisory_unlock(#{CheckSwhidBatchWorker::ADVISORY_LOCK})")
      connection.close
    end
  end

  test "a rescan during the request is checked in another batch without overwriting its identifier" do
    project = create_project(1)
    old_ids = identifiers(project)
    new_revision = data(2).fetch("revision")
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: old_ids.to_json).to_return do
      project.update!(swhids: project.swhids.merge("revision" => new_revision))
      { body: old_ids.to_h { |id| [id, { known: true }] }.to_json }
    end
    CheckSwhidBatchWorker.enqueue(project.id)

    CheckSwhidBatchWorker.perform_one

    assert_equal new_revision, project.reload.swhids["revision"]
    assert_equal [project.id.to_s], pending_ids
    assert_equal 1, CheckSwhidBatchWorker.jobs.size
    request = known_request([new_revision.fetch("swhid")])
    CheckSwhidBatchWorker.perform_one
    assert_requested request, times: 1
    assert_equal "archived", project.reload.swhids.dig("revision", "archive", "status")
    assert_empty pending_ids
  end

  if ENV["SWH_LIVE_TEST"] == "true"
    test "live sync batches known identifiers across projects and persists their coverage" do
      revision = "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
      directory = "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
      first = create_project(1)
      second = create_project(2)
      first.update!(swhids: { "revision" => { "status" => "success", "swhid" => revision } })
      second.update!(swhids: { "directory" => { "status" => "success", "swhid" => directory } })
      WebMock.disable_net_connect!(allow: "archive.softwareheritage.org", allow_localhost: true)

      [first, second].each(&:fetch_swhids_async)
      FetchSwhidWorker.drain
      CheckSwhidBatchWorker.perform_one

      assert_equal "archived", first.reload.swhids.dig("revision", "archive", "status"), first.swhids.inspect
      assert_equal "archived", second.reload.swhids.dig("directory", "archive", "status"), second.swhids.inspect
      assert_requested :post, SwhidArchiveChecker::ENDPOINT, times: 1, body: [revision, directory].to_json
      assert_empty pending_ids
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  def create_project(number)
    Project.create!(url: "https://github.com/batch/project-#{number}", science_score: 42, repository: {}, swhids: data(number))
  end

  def data(number)
    { "status" => "success", "origin" => "https://github.com/batch/project-#{number}",
      "revision" => { "status" => "success", "swhid" => "swh:1:rev:#{format('%040x', number)}" },
      "directory" => { "status" => "success", "swhid" => "swh:1:dir:#{format('%040x', number)}" } }
  end

  def identifiers(*projects)
    projects.flat_map { |project| project.swhids.values_at("revision", "directory").map { |object| object.fetch("swhid") } }
  end

  def known_request(ids)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT).with(body: ids.uniq.to_json)
      .to_return(body: ids.to_h { |id| [id, { known: true }] }.to_json)
  end

  def pending_ids
    Sidekiq.redis { |redis| redis.call("ZRANGE", CheckSwhidBatchWorker::PENDING_KEY, 0, -1) }
  end
end
