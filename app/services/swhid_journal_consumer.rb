require "msgpack"

class SwhidJournalConsumer
  TOPIC = "swh.journal.objects.origin_visit_status"
  BATCH_SIZE = 1_000
  FLUSH_INTERVAL = 1.second

  attr_reader :consumer

  def self.configuration(env = ENV)
    required = %w[BROKERS GROUP_ID USERNAME PASSWORD].to_h do |name|
      key = "SWH_JOURNAL_#{name}"
      value = env.fetch(key)
      raise ArgumentError, "#{key} must not be blank" if value.strip.empty?

      [name, value]
    end
    {
      "bootstrap.servers" => required.fetch("BROKERS"),
      "group.id" => required.fetch("GROUP_ID"),
      "security.protocol" => "SASL_SSL",
      "sasl.mechanism" => "SCRAM-SHA-512",
      "sasl.username" => required.fetch("USERNAME"),
      "sasl.password" => required.fetch("PASSWORD"),
      "auto.offset.reset" => "latest",
      "enable.auto.commit" => false,
      "enable.auto.offset.store" => false
    }
  end

  def initialize(consumer: nil)
    unless consumer
      require "rdkafka"
      consumer = Rdkafka::Config.new(self.class.configuration).consumer
    end
    @consumer = consumer
    @decoder = MessagePack::Factory.new
    @decoder.register_type(-1, Time, unpacker: MessagePack::Time::Unpacker)
    @stopping = false
  end

  def stop
    @stopping = true
  end

  def run
    consumer.subscribe(TOPIC)
    messages = []
    deadline = monotonic_time + FLUSH_INTERVAL
    until @stopping
      message = consumer.poll(100)
      messages << message if message
      next unless messages.size >= BATCH_SIZE || monotonic_time >= deadline

      flush(messages)
      messages.clear
      deadline = monotonic_time + FLUSH_INTERVAL
    end
    flush(messages)
  ensure
    consumer.close
  end

  def flush(messages)
    return if messages.empty?

    Rails.application.executor.wrap do
      events = messages.filter_map { |message| event(message.payload) }
      SwhidJournalDispatcher.new.dispatch(events)
    end
    messages.each { |message| consumer.store_offset(message) }
    consumer.commit
  end

  def event(payload)
    return if payload.nil?

    data = @decoder.unpack(payload)
    raise ArgumentError, "Invalid SWH journal event" unless data.is_a?(Hash)
    return unless %w[full partial failed not_found].include?(data["status"])
    return if data["type"] && data["type"] != "git"

    unless data["origin"].is_a?(String) && data["origin"].present? &&
        data["visit"].is_a?(Integer) && data["visit"].positive? && data["date"].is_a?(Time) &&
        (data["snapshot"].nil? || data["snapshot"].is_a?(String) && data["snapshot"].bytesize == 20) &&
        (data["status"] != "full" || data["snapshot"])
      raise ArgumentError, "Invalid SWH journal visit status"
    end

    data.slice("origin", "visit", "status").merge("date" => data["date"].utc.iso8601(9))
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
