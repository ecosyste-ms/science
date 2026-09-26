require "test_helper"
require "msgpack"
require "rake"
require_relative "../support/swhid_pipeline"

class SwhidJournalConsumerTest < ActiveSupport::TestCase
  include SwhidPipeline

  ORIGIN = "https://github.com/simonehagey/orbdot"
  REVISION = "swh:1:rev:817c61051b31ce4d0eb73d1b873c02de87ce1f81"
  DIRECTORY = "swh:1:dir:b3bb6ae45c8b3cb7ee9d9c3b84b1319cda7060d0"
  Message = Struct.new(:payload)

  class Broker
    attr_accessor :on_empty
    attr_reader :topics, :stored, :commits, :closed

    def initialize(payloads)
      @messages = payloads.map { |payload| Message.new(payload) }
      @stored = []
      @commits = 0
    end

    def subscribe(topic)
      @topics = [topic]
    end

    def poll(_timeout)
      return @messages.shift if @messages.any?

      on_empty.call
      nil
    end

    def store_offset(message)
      @stored << message
    end

    def commit
      @commits += 1
    end

    def close
      @closed = true
    end
  end

  setup do
    travel_to Time.utc(2026, 9, 26, 12)
    CheckSwhidVisitWorker.clear
    CheckSwhidArchivalWorker.clear
    @encoder = MessagePack::Factory.new
    @encoder.register_type(-1, Time, packer: MessagePack::Time::Packer)
    @project = Project.create!(url: ORIGIN, science_score: 42, repository: { "clone_url" => ORIGIN }, swhids: {
      "status" => "success", "origin" => ORIGIN,
      "revision" => { "status" => "success", "swhid" => REVISION },
      "directory" => { "status" => "success", "swhid" => DIRECTORY }
    })
    known_request(false)
    @submission = stub_request(:post, SwhidArchiver::ENDPOINT)
      .with(query: { visit_type: "git", origin_url: ORIGIN }).to_return(body: api_result.to_json)
    perform_fetch(@project.id)
    @baseline = @project.reload.swhids.fetch("archival").deep_dup
    travel 1.minute
  end

  teardown do
    CheckSwhidVisitWorker.clear
    CheckSwhidArchivalWorker.clear
    travel_back
  end

  test "rake consumer decodes a binary visit event and confirms the exact SWHIDs before the next poll" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("swhids:consume")
    service, broker = consumer([payload])
    SwhidJournalConsumer.expects(:new).returns(service)
    Rake::Task["swhids:consume"].reenable
    Rake::Task["swhids:consume"].invoke

    assert_equal [SwhidJournalConsumer::TOPIC], broker.topics
    assert_equal 1, broker.stored.size
    assert_equal 1, broker.commits
    assert broker.closed
    assert_equal 1.minute.from_now.to_f, CheckSwhidVisitWorker.jobs.sole.fetch("at")
    assert_equal @baseline, @project.reload.swhids.fetch("archival")

    known_request(true)
    poll = stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/")
      .to_return(body: api_result(task: "succeeded").to_json)
    travel 1.minute
    CheckSwhidVisitWorker.perform_one

    request = @project.reload.swhids.fetch("archival")
    assert_equal "completed", request["status"]
    assert_equal [REVISION, DIRECTORY].sort, request["confirmed_swhids"].sort
    assert_equal @baseline["before_request"], request["before_request"]
    assert_equal "full", request.dig("journal_event", "status")
    assert_equal({ "total" => 2, "revisions" => 1, "directories" => 1 }, SwhidArchiver.contribution_counts)
    assert_requested poll, times: 1
    assert_requested @submission, times: 1
  end

  test "high volume is queried in batches and repeated origins are coalesced" do
    payloads = 1_001.times.map { |i| payload("origin" => "https://example.org/repo/#{i}") }
    payloads.insert(0, payload("status" => "partial"))
    payloads.insert(1, payload("date" => Time.current + 1))
    queries = []
    callback = ->(_name, _start, _finish, _id, event) { queries << event[:sql] if event[:sql].include?("lower(swhids") }
    service, broker = consumer(payloads)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { service.run }

    assert_equal 2, queries.size
    assert_equal 2, broker.commits
    assert_equal payloads.size, broker.stored.size
    assert_equal 1, CheckSwhidVisitWorker.jobs.size
    assert_equal "full", CheckSwhidVisitWorker.jobs.sole["args"].last["status"]
  end

  test "unrelated origins ongoing visits other loaders tombstones and stale visits do not queue checks" do
    service, broker = consumer([
      payload("origin" => "https://example.org/other"), payload("status" => "ongoing"),
      payload("type" => "svn"), nil, payload("date" => 1.day.ago)
    ])
    service.run

    assert_empty CheckSwhidVisitWorker.jobs
    assert_equal 5, broker.stored.size
    assert_equal 1, broker.commits
  end

  test "origin matching accounts for case and submitted clone URLs" do
    data = @project.swhids.deep_dup
    data["archival"]["origin"] = "#{ORIGIN}.git"
    @project.update!(swhids: data)
    service, = consumer([payload("origin" => "#{ORIGIN.upcase}.git")])
    service.run

    assert_equal @project.id, CheckSwhidVisitWorker.jobs.sole["args"].first
  end

  test "duplicate delivery and older events do not repeatedly poll a pending request" do
    service, = consumer([payload, payload])
    service.run
    args = CheckSwhidVisitWorker.jobs.sole["args"]
    poll = stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(body: api_result.to_json)
    CheckSwhidVisitWorker.new.perform(*args)
    CheckSwhidVisitWorker.new.perform(*args)
    older = args.last.merge("date" => 30.seconds.ago.iso8601(9))
    CheckSwhidVisitWorker.new.perform(@project.id, 123, older)

    assert_requested poll, times: 1
    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_equal 6.hours.from_now.iso8601, @project.swhids.dig("archival", "next_check_at")
    CheckSwhidVisitWorker.clear
    service, = consumer([payload])
    service.run
    assert_empty CheckSwhidVisitWorker.jobs
  end

  test "queued events cannot wake a replaced or completed request" do
    service, = consumer([payload])
    service.run
    args = CheckSwhidVisitWorker.jobs.sole["args"]
    data = @project.swhids.deep_dup
    data["archival"]["id"] = 456
    @project.update!(swhids: data)
    CheckSwhidVisitWorker.new.perform(*args)
    data["archival"].merge!("id" => 123, "status" => "completed")
    @project.update!(swhids: data)
    CheckSwhidVisitWorker.new.perform(*args)

    assert_not_requested :get, /origin\/save\//
    assert_nil @project.reload.swhids.dig("archival", "journal_event")
  end

  test "non-scientific projects are excluded" do
    @project.update!(science_score: 0)
    service, = consumer([payload])
    service.run
    assert_empty CheckSwhidVisitWorker.jobs
  end

  test "a journal event preserves request rate limits" do
    data = @project.swhids.deep_dup
    data["archival"]["retry_at"] = 1.hour.from_now.iso8601
    @project.update!(swhids: data)
    service, = consumer([payload])
    service.run
    CheckSwhidVisitWorker.perform_one

    assert_equal 1.hour.from_now.iso8601, @project.reload.swhids.dig("archival", "next_check_at")
    assert_not_requested :get, /origin\/save\//
  end

  test "global API cooldown defers event checks" do
    service, = consumer([payload])
    service.run
    SwhidApi.stubs(:check_rate_limit!).raises(SwhidApi::RateLimited.new(1.hour.from_now))
    CheckSwhidVisitWorker.perform_one

    assert_equal "pending", @project.reload.swhids.dig("archival", "status")
    assert_operator CheckSwhidWorker.jobs.last.fetch("at"), :>, 1.hour.from_now.to_f
    assert_not_requested :get, /origin\/save\//
  end

  test "failed visits trigger verification without claiming successful archival" do
    service, = consumer([payload("status" => "failed", "snapshot" => nil)])
    service.run
    stub_request(:get, "#{SwhidArchiver::ENDPOINT}123/").to_return(body: api_result(task: "failed").to_json)
    CheckSwhidVisitWorker.perform_one

    assert_equal "failed", @project.reload.swhids.dig("archival", "status")
    assert_equal 0, SwhidArchiver.contribution_counts["total"]
  end

  test "queue failures close the consumer without advancing offsets" do
    service, broker = consumer([payload])
    Sidekiq::Client.expects(:push_bulk).raises(IOError, "queue unavailable")
    assert_raises(IOError) { service.run }
    assert_empty broker.stored
    assert_equal 0, broker.commits
    assert broker.closed
  end

  test "a rejected bulk enqueue leaves offsets available for replay" do
    service, broker = consumer([payload])
    Sidekiq::Client.expects(:push_bulk).returns([nil])
    assert_raises(RuntimeError) { service.run }
    assert_empty broker.stored
    assert_equal 0, broker.commits
  end

  test "malformed events stop consumption without acknowledging the batch" do
    ["\xc1".b, payload("date" => "invalid"), payload("snapshot" => nil)].each do |invalid|
      service, broker = consumer([invalid])
      assert_raises(MessagePack::MalformedFormatError, ArgumentError) { service.run }
      assert_empty broker.stored
      assert_equal 0, broker.commits
      assert broker.closed
    end
  end

  test "configuration requires Kafka credentials and disables automatic offset advancement" do
    env = { "SWH_JOURNAL_BROKERS" => "broker.example:9093", "SWH_JOURNAL_GROUP_ID" => "science-prod-01-visits",
      "SWH_JOURNAL_USERNAME" => "science-prod-01", "SWH_JOURNAL_PASSWORD" => "secret" }
    config = SwhidJournalConsumer.configuration(env)
    assert_equal "SASL_SSL", config["security.protocol"]
    assert_equal "SCRAM-SHA-512", config["sasl.mechanism"]
    assert_equal "latest", config["auto.offset.reset"]
    assert_equal false, config["enable.auto.commit"]
    assert_equal false, config["enable.auto.offset.store"]
    assert_raises(KeyError) { SwhidJournalConsumer.configuration({ "SWH_API_TOKEN" => "api-token" }) }
    assert_raises(ArgumentError) { SwhidJournalConsumer.configuration(env.merge("SWH_JOURNAL_PASSWORD" => " ")) }
  end

  def consumer(payloads)
    broker = Broker.new(payloads)
    service = SwhidJournalConsumer.new(consumer: broker)
    broker.on_empty = -> { service.stop }
    [service, broker]
  end

  def payload(overrides = {})
    data = { "origin" => ORIGIN, "visit" => 42, "date" => Time.current,
      "status" => "full", "snapshot" => ["a" * 40].pack("H*"), "type" => "git", "metadata" => nil }.merge(overrides)
    data["date"] = data["date"].to_time if data["date"].respond_to?(:to_time)
    @encoder.pack(data)
  end

  def known_request(known)
    stub_request(:post, SwhidArchiveChecker::ENDPOINT)
      .to_return(body: { REVISION => { known: known }, DIRECTORY => { known: known } }.to_json)
  end

  def api_result(task: "scheduled")
    { "id" => 123, "origin_url" => ORIGIN, "visit_type" => "git", "save_request_date" => Time.utc(2026, 9, 26, 12).iso8601,
      "save_request_status" => "accepted", "save_task_status" => task }
  end
end
