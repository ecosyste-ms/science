class OpenAlexSoftwareClient
  PAGE_SIZE = 100
  FIELDS = "id,doi,display_name,type,created_date,updated_date,primary_location,locations".freeze
  SORT = "ids.openalex:asc".freeze

  def self.identifier(value)
    raise ArgumentError, "invalid OpenAlex work ID" unless value.is_a?(String)
    id = value.sub(%r{\Ahttps://openalex\.org/}i, "").upcase
    raise ArgumentError, "invalid OpenAlex work ID" unless id.match?(/\AW[1-9][0-9]*\z/)
    id
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 100 OpenAlex work IDs" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def self.date(value)
    raise ArgumentError, "expected an ISO date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    Date.iso8601(value).iso8601
  end

  def self.initial_cursor(from: nil, until_time: nil)
    upper = date(until_time || Date.yesterday.iso8601)
    lower = date(from) if from
    raise ArgumentError, "FROM must not follow UNTIL" if lower && lower > upper
    JSON.generate("from" => lower, "until" => upper, "token" => "*", "last_id" => nil,
      "select" => FIELDS, "sort" => SORT)
  end

  def initialize(client: OpenAlexApiClient.new)
    @client = client
    @client.connection.options.open_timeout = 5
    @client.connection.options.timeout = 60
  end

  def page(after:, limit: PAGE_SIZE)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    state = JSON.parse(after)
    lower = self.class.date(state["from"]) if state["from"]
    upper = self.class.date(state.fetch("until"))
    unless state["select"] == FIELDS && state["sort"] == SORT && state["token"].is_a?(String) && state["token"].present?
      raise ArgumentError, "invalid OpenAlex cursor configuration"
    end
    self.class.identifier(state["last_id"]) if state["last_id"]
    filter = lower ? "type:software,from_updated_date:#{lower},to_updated_date:#{upper}" : "type:software,to_created_date:#{upper}"
    retrieved_at = Time.current
    body = @client.get("works", filter: filter, sort: SORT, per_page: limit, select: FIELDS, cursor: state.fetch("token"))
    rows = body.fetch("results")
    token = body.fetch("meta").fetch("next_cursor")
    unless rows.is_a?(Array) && rows.size <= limit && (token.nil? || (token.is_a?(String) && token.present?))
      raise OpenAlexApiClient::RequestError, "Invalid OpenAlex software page"
    end
    ids = rows.map do |row|
      raise OpenAlexApiClient::RequestError, "Unexpected OpenAlex work type" unless row.is_a?(Hash) && row["type"] == "software"
      self.class.identifier(row.fetch("id"))
    end
    ordered = [state["last_id"], *ids].compact
    unless ordered.each_cons(2).all? { |left, right| left < right } && !(rows.empty? && token) && token != state["token"]
      raise OpenAlexApiClient::RequestError, "OpenAlex cursor did not advance in ID order"
    end
    next_cursor = JSON.generate(state.merge("token" => token, "last_id" => ids.last || state["last_id"])) if token
    { records: rows, next_cursor: next_cursor, retrieved_at: retrieved_at }
  rescue JSON::ParserError, KeyError, TypeError => error
    raise OpenAlexApiClient::RequestError, "Invalid OpenAlex software page: #{error.class}"
  end

  def record(id)
    id = self.class.identifier(id)
    @client.get("works/#{id}", select: FIELDS)
  end
end
