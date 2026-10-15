class JorsClient < JournalHttpClient
  HOST = "openresearchsoftware.metajnl.com"
  CATALOGUE_URL = "https://#{HOST}/en/articles"
  PAGE_SIZE = 5

  def self.identifier(value)
    id = value.to_s.strip.downcase.sub(%r{\Ahttps?://(?:dx\.)?doi\.org/}, "")
    raise ArgumentError, "invalid JORS DOI" unless id.match?(%r{\A10\.5334/jors\.[a-z0-9]+\z})
    id
  end

  def self.article_url(id)
    "https://#{HOST}/articles/#{identifier(id)}"
  end

  def self.validate_ids!(ids)
    raise ArgumentError, "expected 1 to 5 JORS DOIs" unless ids.is_a?(Array) && ids.size.between?(1, PAGE_SIZE)
    ids.map { |id| identifier(id) }.uniq
  end

  def page(after: nil, limit: PAGE_SIZE)
    raise ArgumentError, "limit must be between 1 and 5" unless limit.is_a?(Integer) && limit.between?(1, PAGE_SIZE)
    raise ArgumentError, "invalid JORS cursor" if after && !after.match?(/\A[1-9][0-9]{0,3}:[0-9]{1,3}\z/)
    page, offset = after ? after.split(":").map(&:to_i) : [1, 0]
    catalogue = catalogue_page(page)
    ids = catalogue.fetch("ids")
    raise Error, "JORS page changed before saved offset" if offset >= ids.size
    selected = ids.slice(offset, limit)
    next_cursor = if offset + selected.size < ids.size
      "#{page}:#{offset + selected.size}"
    elsif catalogue.fetch("has_next")
      "#{page + 1}:0"
    end
    records(selected).merge(next_cursor: next_cursor)
  end

  def catalogue_page(page)
    Rails.cache.fetch("jors-page:#{page}", expires_in: 6.hours) do
      doc = Nokogiri::HTML(request("#{CATALOGUE_URL}?page=#{page}"))
      raise Error, "Missing JORS article listing" unless doc.at_css("title")&.text.to_s.include?("Journal of Open Research Software")
      ids = doc.css("a[href]").filter_map do |link|
        uri = URI.join(CATALOGUE_URL, link["href"])
        match = uri.path.match(%r{\A/(?:en/)?articles/(10\.5334/jors\.[a-z0-9]+)/?\z}i)
        self.class.identifier(match[1]) if match && uri.host == HOST && uri.userinfo.nil?
      end.uniq
      raise Error, "Invalid JORS listing size" unless ids.size.between?(1, 100)
      next_link = doc.css("a[href]").find { |link| link.text.squish == "Next page" }
      if next_link
        uri = URI.join(CATALOGUE_URL, next_link["href"])
        unless uri.host == HOST && %w[/en/articles /articles /articles/].include?(uri.path) &&
            URI.decode_www_form(uri.query.to_s).to_h == { "page" => (page + 1).to_s }
          raise Error, "Invalid JORS next page"
        end
      end
      { "ids" => ids, "has_next" => next_link.present? }
    end
  rescue URI::InvalidURIError => error
    raise Error, "Invalid JORS listing URL: #{error.class.name}"
  end

  def records(ids)
    ids = self.class.validate_ids!(ids)
    started_at = Time.current
    { records: ids.map { |id| article(id) }, retrieved_at: started_at }
  end

  def article(id)
    id = self.class.identifier(id)
    url = self.class.article_url(id)
    doc = Nokogiri::HTML(request(url))
    links = doc.css("a[href]").select { |link| link.text.squish == "XML (English)" }.map { |link| URI.join(url, link["href"]).to_s }.uniq
    raise Error, "Expected one JORS XML download" unless links.one?
    xml_url = links.sole
    uri = URI.parse(xml_url)
    raise Error, "Invalid JORS XML download" unless uri.path.match?(%r{\A/articles/[0-9]+/files/[a-zA-Z0-9_./-]+\.xml\z}) && !uri.path.split("/").include?("..")
    parse_article(request(xml_url), id).merge("xml_url" => xml_url)
  rescue URI::InvalidURIError => error
    raise Error, "Invalid JORS article URL: #{error.class.name}"
  end

  def parse_article(body, id)
    doc = Nokogiri::XML(body) { |config| config.strict.nonet }
    doc.remove_namespaces!
    meta = doc.at_xpath("/article/front/article-meta")
    doi = meta&.at_xpath('./article-id[@pub-id-type="doi"]')&.text
    raise Error, "JORS XML DOI mismatch" unless doi && self.class.identifier(doi) == id
    title = meta.at_xpath("./title-group/article-title")&.text&.squish
    categories = meta.xpath("./article-categories//subject").map { |node| node.text.squish }
    raise Error, "Missing JORS article metadata" if title.blank? || categories.empty?
    eligible = categories.any? { |category| category.match?(/\Asoftware metapapers?\z/i) }
    sections = eligible ? doc.xpath("//body//sec").select { |sec| sec.at_xpath("./title")&.text.to_s.match?(/\b(?:software location|code repositor(?:y|ies))\b/i) } : []
    urls = sections.flat_map { |sec| section_urls(sec) }.uniq
    code = urls.select { |url| repository_url?(url) }
    sections.each do |section|
      next unless section.text.match?(/\bName:\s*GitHub\b/i)
      section.text.scan(/\bIdentifier:\s*([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\b/).flatten.each do |name|
        candidate = "https://github.com/#{name}"
        corroborated = doc.xpath("//ext-link").any? { |link| RepositoryUrlNormalizer.normalize(link["href"]) == RepositoryUrlNormalizer.normalize(candidate) }
        code << candidate if corroborated && repository_url?(candidate)
      end
    end
    date = meta.xpath("./pub-date").find { |node| node["date-type"] == "pub" || node["pub-type"] == "epub" }
    published = date&.at_xpath("./day") && Date.new(date.at_xpath("./year").text.to_i, date.at_xpath("./month").text.to_i, date.at_xpath("./day").text.to_i).iso8601
    { "id" => id, "doi" => id, "article_url" => self.class.article_url(id), "title" => title,
      "categories" => categories, "eligible" => eligible, "publication_date" => published,
      "code_urls" => code.uniq, "software_links" => urls - code,
      "software_sections" => sections.map { |sec| { "heading" => sec.at_xpath("./title").text.squish, "text" => sec.text.squish } } }
  rescue Nokogiri::XML::SyntaxError, ArgumentError => error
    raise Error, "Invalid JORS XML: #{error.message.truncate(200)}"
  end

  def section_urls(section)
    (section.xpath(".//ext-link").filter_map { |link| link["href"] } +
      section.text.scan(%r{https?://[^\s<>"\[\]]+})).map { |url| url.sub(/[.,;)]+\z/, "") }.uniq
  end

end
