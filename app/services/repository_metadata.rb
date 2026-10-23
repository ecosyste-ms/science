require "yaml"

class RepositoryMetadata
  attr_reader :frontmatter, :document, :brief, :body, :slug

  GENERIC_HEADING = /\A(?:model (?:overview|card|details|description)|overview|introduction|usage|installation|getting started)\z/i

  def initialize(readme:, brief:, slug: nil)
    @brief = brief || {}
    @slug = slug
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

    headings = document.css("h1, h2").filter_map { |node| node.text.squish.sub(/\AModel card for\b[:\s]*/i, "").presence }
    # Notices and section titles often come first, so only trust a heading that resembles the repository name.
    return headings.find { |heading| !heading.match?(GENERIC_HEADING) && matches_slug?(heading) } if slug.present?

    headings.first unless headings.first&.match?(GENERIC_HEADING)
  end

  def matches_slug?(heading)
    text = heading.downcase.gsub(/[^a-z0-9]/, "")
    target = slug.downcase.gsub(/[^a-z0-9]/, "")
    return false if text.length < 3 || target.length < 3

    text.include?(target) || target.include?(text) ||
      DidYouMean::Levenshtein.distance(text, target) <= target.length / 5
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
