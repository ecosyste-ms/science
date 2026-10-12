require "bibtex"
require "cgi"

class FilePaperCandidates
  ARXIV = /(?:\d{4}\.\d{4,5}|[a-z][a-z.-]*(?:\.[A-Z]{2})?\/\d{7})(?:v\d+)?/i

  attr_reader :file, :text, :lines, :diagnostics, :candidates

  def initialize(file)
    @file = file
    @text = file.fetch("content")
    @lines = text.lines
    @diagnostics = []
    @candidates = {}
  end

  def extract(brief_entries: [])
    lines.each_with_index do |line, index|
      identifiers(line).each { |kind, identifier| add(kind, identifier, occurrence(index, index, "text")) }
    end
    entries = bibtex_entries
    brief_entries.each do |entry|
      line = entry["line"].to_i - 1
      next unless line.between?(0, lines.length - 1)

      found = entries.find { |item| item[:first] == line && item[:key] == entry["key"] }
      unless found
        found = { first: line, last: entry_end(line), key: entry["key"], fields: {} }
        entries << found
      end
      found[:brief] = entry
    end
    entries.each do |entry|
      fields = entry[:fields]
      brief = entry[:brief] || {}
      title = brief["title"].presence || fields["title"]
      details = occurrence(entry[:first], entry[:last], "bibtex").merge(
        "title" => title, "fields" => fields, "brief_entry" => entry[:brief])
      refs = identifiers([fields["doi"], fields["url"], fields["eprint"], brief["doi"], brief["url"], brief["eprint"]].compact.join("\n"))
      if fields["archiveprefix"].to_s.casecmp?("arxiv") && fields["eprint"].to_s.match?(/\A#{ARXIV}\z/)
        refs << ["arxiv", normalize_arxiv(fields["eprint"])]
      end
      refs << ["citation_title", title] if refs.empty? && title.present?
      refs.uniq.each { |kind, identifier| add(kind, identifier, details) }
    end
    candidates.values
  end

  def identifiers(value)
    refs = []
    remaining = value.gsub(%r{https?://[^\s<>"'`{}\[\]]+}i) do |raw|
      url = trim(CGI.unescapeHTML(raw))
      begin
        uri = URI.parse(url)
        host = uri.host.to_s.downcase.delete_prefix("www.")
        path = URI::DEFAULT_PARSER.unescape(uri.path).delete_suffix("/")
        case host
        when "doi.org", "dx.doi.org"
          add_doi(refs, path.delete_prefix("/"))
        when "arxiv.org", "export.arxiv.org"
          id = path.sub(%r{\A/(?:abs|pdf|html)/}, "").sub(/\.pdf\z/i, "")
          refs << ["arxiv", normalize_arxiv(id)] if id.match?(/\A#{ARXIV}\z/)
        when "biorxiv.org", "medrxiv.org"
          doi = path.delete_prefix("/content/").sub(/v\d+(?:\.full(?:\.pdf)?)?\z/i, "")
          add_doi(refs, doi)
        when "aclanthology.org", "aclweb.org"
          id = path.delete_prefix("/anthology/").delete_prefix("/").delete_suffix(".pdf")
          refs << ["acl_id", id] if id.match?(/\A(?:[A-Z]\d{2}-\d+|\d{4}\.[\w-]+\.\d+)\z/i)
        when "openreview.net"
          id = URI.decode_www_form(uri.query.to_s).to_h["id"]
          refs << ["openreview_id", id] if %w[/forum /pdf].include?(path) && id.present?
        when "api.semanticscholar.org", "semanticscholar.org"
          id = path[%r{(?:\A|/)CorpusID:(\d+)\z}i, 1]
          refs << ["semantic_scholar_corpus_id", id] if id
        else
          refs << ["paper_url", url] if path.match?(/\.pdf\z/i)
        end
      rescue URI::InvalidURIError, ArgumentError
        nil
      end
      " "
    end
    remaining.scan(/\barxiv\s*:\s*(#{ARXIV})(?![\w.])/i) { |match| refs << ["arxiv", normalize_arxiv(match.first)] }
    remaining.scan(%r{(?<![\w.-])arxiv\.org/(?:abs|pdf|html)/(#{ARXIV})}i) { |match| refs << ["arxiv", normalize_arxiv(match.first)] }
    remaining.scan(%r{\b10\.\d{4,9}/[^\s<>"'{}\[\]`]+}i) { |doi| add_doi(refs, trim(doi)) }
    refs.uniq
  end

  def trim(value)
    value = value.sub(/[.,;!]+\z/, "")
    value = value.chop while value.end_with?(")") && value.count(")") > value.count("(")
    value.sub(/[.,;!]+\z/, "")
  end

  def normalize_arxiv(value)
    value.sub(/v\d+\z/i, "").downcase
  end

  def add_doi(refs, doi)
    return unless doi.match?(%r{\A10\.\d{4,9}/\S+\z}i)

    if doi.match?(%r{\A10\.48550/arxiv\.#{ARXIV}\z}i)
      refs << ["arxiv", normalize_arxiv(doi.sub(%r{\A10\.48550/arxiv\.}i, ""))]
    else
      refs << ["doi", doi.downcase]
    end
  end

  def bibtex_entries
    bibliography = BibTeX.parse(text, strict: false, parse_names: false)
    diagnostics.concat(bibliography.errors.map(&:to_s))
    bibliography.replace.join
    positions = Hash.new(0)
    bibliography.select { |element| element.is_a?(BibTeX::Entry) }.filter_map do |entry|
      pattern = /^[\t ]*@#{Regexp.escape(entry.type.to_s)}\s*\{\s*#{Regexp.escape(entry.key)}\s*,/i
      match = pattern.match(text, positions[entry.key])
      next unless match

      positions[entry.key] = match.end(0)
      first = text[0...match.begin(0)].count("\n")
      { first: first, last: entry_end(first), key: entry.key,
        fields: entry.fields.transform_keys { |key| key.to_s.downcase }.transform_values(&:to_s) }
    end
  rescue BibTeX::ParseError => error
    diagnostics << error.message
    []
  end

  def entry_end(first)
    ending = ((first + 1)...lines.length).find { |index| lines[index].match?(/^[\t ]*(?:```|~~~|@\w+\s*\{)/) }
    (ending || lines.length) - 1
  end

  def occurrence(first, last, source)
    { "source" => source, "line_start" => first + 1, "line_end" => last + 1,
      "section" => sections[first],
      "raw" => lines[first..last].join,
      "context_line_start" => [first - 2, 0].max + 1,
      "context" => lines[[first - 2, 0].max..[last + 2, lines.length - 1].min].join }
  end

  def sections
    @sections ||= begin
      heading = {}
      fence = nil
      frontmatter = lines.first&.strip == "---"
      lines.each_with_index.map do |line, index|
        if frontmatter
          frontmatter = false if index.positive? && line.strip == "---"
          next []
        end
        if (marker = line.match(/^\s*(`{3,}|~{3,})/))
          if fence
            fence = nil if marker[1][0] == fence[0] && marker[1].length >= fence.length && line.strip == marker[1]
          else
            fence = marker[1]
          end
        elsif !fence && (match = line.match(/^\s*(\#{1,6})\s+(.+?)\s*#*\s*$/))
          level = match[1].length
          heading.delete_if { |key, _| key >= level }
          heading[level] = match[2]
        end
        heading.sort.map(&:last)
      end
    end
  end

  def add(kind, identifier, occurrence)
    candidate = candidates[[kind, identifier]] ||= {
      "identifier_kind" => kind, "identifier" => identifier, "relation" => nil, "occurrences" => [] }
    candidate["occurrences"] << occurrence unless candidate["occurrences"].include?(occurrence)
  end
end
