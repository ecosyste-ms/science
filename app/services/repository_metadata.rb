require "yaml"

class RepositoryMetadata
  attr_reader :frontmatter, :document, :brief, :body

  BOILERPLATE_HEADINGS = Set[
    "model overview", "model card", "model details", "model description", "overview", "introduction", "usage",
    "installation", "install", "getting started", "quick start", "quickstart", "setup", "attention", "warning",
    "note", "notes", "important", "notice", "news", "updates", "announcement", "announcements", "requirements",
    "prerequisites", "dependencies", "contents", "table of contents", "toc", "motivation", "synopsis", "about",
    "abstract", "summary", "description", "license", "citation", "how to cite", "acknowledgements",
    "acknowledgments", "contributing", "contact", "authors", "changelog", "faq", "documentation", "examples", "welcome"
  ].freeze

  def initialize(readme:, brief:)
    @brief = brief || {}
    text = readme.to_s
    frontmatter = text.match(/\A---\s*\r?\n(.*?)\r?\n(?:---|\.\.\.)\s*(?:\r?\n|\z)/m)
    @frontmatter = parse_card(frontmatter&.[](1))
    @body = frontmatter ? text[frontmatter.end(0)..] : text
    @document = Nokogiri::HTML.fragment(Redcarpet::Markdown.new(
      Redcarpet::Render::HTML, fenced_code_blocks: true, tables: true, lax_spacing: true
    ).render(body))
  end

  def parse_card(text)
    parsed = YAML.safe_load(text.to_s, permitted_classes: [Date], aliases: false)
    parsed.is_a?(Hash) ? parsed : {}
  rescue Psych::Exception
    {}
  end

  def strings(value)
    Array.wrap(value).filter_map { |item| item.squish.presence if item.is_a?(String) }.uniq
  end

  def name
    title = strings(frontmatter["title"]).first
    return title if title

    heading = document.at_css("h1, h2")&.text&.squish&.sub(/\AModel card for\b[:\s]*/i, "")&.presence
    heading unless heading.nil? || boilerplate?(heading)
  end

  def boilerplate?(heading)
    return true if heading.strip.end_with?(":")

    text = heading.downcase.gsub(/:[a-z0-9_+-]+:/, " ").gsub(/[^a-z\s\/&]/, " ").squish
    text.empty? || text.split(%r{\s*(?:/|&|\band\b)\s*}).all? { |part| BOILERPLATE_HEADINGS.include?(part.squish) }
  end

  def description
    structured = strings(frontmatter["description"]).first
    return structured if structured

    content = document.dup
    content.css("script, style, pre, table, blockquote, li").remove
    paragraph = content.css("p").find do |node|
      text = node.text.squish
      text.length >= 40 && node.css("img").empty? &&
        !text.match?(/\A(?:\[?(?:more information needed|model description)|license:)/i)
    end
    paragraph&.text&.squish&.truncate(500, separator: " ")
  end

  def attributes
    languages = Array.wrap(brief["languages"]).filter_map { |entry| entry["name"] if entry.is_a?(Hash) }
    {
      "name" => name,
      "description" => description,
      "topics" => strings(frontmatter["tags"]),
      "language" => languages.first,
      "license" => brief.dig("resources", "license_type")
    }
  end
end
