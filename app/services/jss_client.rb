require "digest"

class JssClient < JournalHttpClient
  HOST = "www.jstatsoft.org"
  CATALOGUE_URL = "https://#{HOST}/oai"
  PAGE_SIZE = 5
  SETS = %w[jss:ART jss:CS].freeze
  class ExpiredCursor < Error; end

  def self.identifier(value)
    raise ArgumentError, "invalid JSS OAI identifier" unless value.is_a?(String) && value.match?(%r{\Aoai:ojs\.pkp\.sfu\.ca:article/[1-9][0-9]*\z})
    value
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 5 JSS identifiers" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def self.timestamp(value)
    return if value.blank?
    value += "T00:00:00Z" if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, "expected a UTC OAI timestamp" unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    Time.iso8601(value).utc.iso8601
  end

  def self.initial_cursor(from: nil, until_time: nil)
    lower = timestamp(from)
    upper = timestamp(until_time || Time.current.utc.iso8601)
    raise ArgumentError, "FROM must not follow UNTIL" if lower && lower > upper
    JSON.generate("set" => SETS.first, "from" => lower, "until" => upper, "token" => nil, "offset" => 0)
  end

  def self.article_url(key)
    raise ArgumentError, "invalid JSS article key" unless key.match?(/\Av\d+[icbs]\d+\z/i)
    "https://#{HOST}/article/view/#{key.downcase}"
  end

  def page(after:, limit: PAGE_SIZE)
    raise ArgumentError, "limit must be between 1 and 5" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    state = JSON.parse(after)
    raise ArgumentError, "invalid JSS cursor" unless SETS.include?(state["set"]) && state["offset"].is_a?(Integer) && state["offset"].between?(0, 1000)
    self.class.timestamp(state.fetch("until"))
    self.class.timestamp(state["from"])
    begin
      feed = listing(state)
    rescue ExpiredCursor
      raise unless state["token"]
      state = state.merge("token" => nil, "offset" => 0)
      feed = listing(state)
    end
    rows = feed.fetch("records")
    offset = state.fetch("offset")
    raise Error, "JSS page changed before saved offset" if offset.positive? && offset >= rows.size
    selected = rows.slice(offset, limit) || []
    next_state = if offset + selected.size < rows.size
      state.merge("offset" => offset + selected.size)
    elsif feed["token"].present?
      raise Error, "JSS repeated its continuation token" if feed["token"] == state["token"]
      state.merge("token" => feed["token"], "offset" => 0)
    elsif state["set"] == SETS.first
      state.merge("set" => SETS.last, "token" => nil, "offset" => 0)
    end
    started_at = Time.current
    { records: selected.map { |row| enrich(row) }, next_cursor: next_state && JSON.generate(next_state), retrieved_at: started_at }
  end

  def listing(state)
    params = if state["token"]
      { verb: "ListRecords", resumptionToken: state["token"] }
    else
      { verb: "ListRecords", metadataPrefix: "oai_dc", set: state.fetch("set"), from: state["from"], until: state.fetch("until") }.compact
    end
    url = "#{CATALOGUE_URL}?#{URI.encode_www_form(params)}"
    key = "jss-oai:#{Digest::SHA256.hexdigest(url)}"
    Rails.cache.fetch(key, expires_in: 20.minutes) { parse_feed(request(url)) }
  end

  def records(ids)
    started_at = Time.current
    records = self.class.validate_ids!(ids).map do |id|
      url = "#{CATALOGUE_URL}?#{URI.encode_www_form(verb: 'GetRecord', metadataPrefix: 'oai_dc', identifier: id)}"
      rows = parse_feed(request(url)).fetch("records")
      raise Error, "JSS record identifier mismatch" unless rows.one? && rows.sole["id"] == id
      enrich(rows.sole)
    end
    { records: records, retrieved_at: started_at }
  end

  def parse_feed(body)
    doc = Nokogiri::XML(body) { |config| config.strict.nonet }
    doc.remove_namespaces!
    raise Error, "Invalid JSS OAI document" unless doc.root&.name == "OAI-PMH"
    error = doc.at_xpath("/OAI-PMH/error")
    raise ExpiredCursor, "JSS continuation token expired" if error && error["code"] == "badResumptionToken"
    raise Error, "JSS OAI error: #{error['code']}" if error && error["code"] != "noRecordsMatch"
    rows = doc.xpath("/OAI-PMH/ListRecords/record | /OAI-PMH/GetRecord/record")
    raise Error, "Unexpected empty JSS OAI response" if rows.empty? && error.nil?
    raise Error, "JSS OAI page exceeds 1000 records" if rows.size > 1000
    records = rows.map do |node|
      header = node.at_xpath("./header")
      id = self.class.identifier(header&.at_xpath("./identifier")&.text)
      stamp = self.class.timestamp(header.at_xpath("./datestamp")&.text)
      raise Error, "Missing JSS datestamp" unless stamp
      next({ "id" => id, "deleted" => true, "datestamp" => stamp }) if header["status"] == "deleted"
      meta = node.at_xpath("./metadata/dc")
      raise Error, "Missing JSS article metadata" unless meta
      sets = header.xpath("./setSpec").map(&:text)
      title = meta.at_xpath("./title")&.text&.squish
      identifiers = meta.xpath("./identifier").map { |item| item.text.strip }
      article = identifiers.filter_map { |value| article_key(value) }.uniq
      raise Error, "Invalid JSS article metadata" if title.blank? || !article.one?
      doi = identifiers.find { |value| value.match?(%r{\A10\.18637/jss\.v\d+\.[icbs]\d+\z}i) }&.downcase
      { "id" => id, "datestamp" => stamp, "article_url" => self.class.article_url(article.sole),
        "title" => title, "doi" => doi, "publication_date" => meta.at_xpath("./date")&.text,
        "sets" => sets, "eligible" => (sets & SETS).any?, "code_urls" => [] }
    end
    { "records" => records, "token" => doc.at_xpath("/OAI-PMH/ListRecords/resumptionToken")&.text&.strip&.presence }
  rescue Nokogiri::XML::SyntaxError, ArgumentError => error
    raise Error, "Invalid JSS OAI metadata: #{error.message.truncate(200)}"
  end

  def article_key(value)
    uri = URI.parse(value)
    return unless %w[http https].include?(uri.scheme) && uri.host == HOST && uri.userinfo.nil? && [80, 443].include?(uri.port)
    uri.path.match(%r{\A/(?:index\.php/jss/)?article/view/(v\d+[icbs]\d+)/?\z}i)&.[](1)&.downcase
  rescue URI::InvalidURIError
    nil
  end

  def enrich(row)
    return row if row["deleted"] || !row["eligible"]
    url = row.fetch("article_url")
    doc = Nokogiri::HTML(request(url))
    doi = doc.at_css('meta[name="citation_doi"]')&.[]("content")&.downcase
    raise Error, "JSS article DOI disagrees with OAI metadata" if row["doi"] && doi != row["doi"]
    raise Error, "Missing JSS citation metadata" unless doc.at_css('meta[name="citation_title"]')
    attachments = doc.css("a[href]").filter_map do |link|
      begin
        uri = URI.join(url, link["href"].strip)
      rescue URI::InvalidURIError
        next
      end
      path = uri.path.sub(%r{\A/index\.php/jss/}, "/")
      next unless uri.host == HOST && path.match?(%r{\A/article/(?:view|download)/#{Regexp.escape(url.split('/').last)}/[0-9]+\z})
      { "label" => link.text.squish, "url" => uri.to_s }
    end.uniq
    packages = attachments.filter_map do |attachment|
      match = attachment["label"].match(/\A(R|Python) package \(([a-zA-Z0-9_.-]+)\)\z/i)
      next unless match
      download = URI.parse(attachment.fetch("url"))
      download.path = download.path.sub(%r{\A/index\.php/jss/}, "/")
      metadata = JournalPackageMetadata.read(request(download.to_s), name: match[2], ecosystem: match[1].casecmp?("R") ? "cran" : "pypi")
      metadata.merge("label" => attachment.fetch("label"), "attachment_url" => attachment.fetch("url"))
    end
    urls = packages.select { |package| package["status"] == "matched" }.flat_map { |package| package.fetch("urls") }.uniq
    row.merge("attachments" => attachments, "subject_packages" => packages,
      "code_urls" => urls.select { |candidate| repository_url?(candidate) })
  rescue URI::InvalidURIError => error
    raise Error, "Invalid JSS attachment URL: #{error.class.name}"
  end
end
