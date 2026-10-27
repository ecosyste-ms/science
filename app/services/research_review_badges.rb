class ResearchReviewBadges
  def self.extract(text)
    text = text.to_s
    linked = linked_badges(text)
    badges = text.scan(%r{https?://[^\s<>"'\[\]()]+}i).filter_map do |url|
      uri = URI.parse(CGI.unescapeHTML(url))
      host = uri.host.to_s.downcase.delete_prefix("www.")
      path = URI::DEFAULT_PARSER.unescape(uri.path)
      case host
      when "pyopensci.org"
        { program: "pyOpenSci", badge_url: url } if path.match?(%r{\A/badges/peer-reviewed\.svg\z}i)
      when "badges.ropensci.org"
        match = path.match(%r{\A/([1-9]\d*)_(status|stats)\.svg\z}i)
        { program: "rOpenSci", badge_url: url, review_id: match[1] } if match
      when "joss.theoj.org"
        match = path.match(%r{\A/papers/((?:doi/10\.21105/joss\.\d+)|[a-f0-9]{32})/status\.svg\z}i)
        { program: "JOSS", badge_url: url, review_id: match[1] } if match
      when "img.shields.io"
        { program: "pyOpenSci", badge_url: url } if path.match?(%r{\A/badge/pyopensci-peer(?:[ _]|--)*reviewed-[a-z]+(?:\.svg)?\z}i)
      end
    rescue URI::InvalidURIError, ArgumentError
      nil
    end
    (linked + badges.reject { |badge| linked.any? { |item| item[:badge_url] == badge[:badge_url] } })
      .uniq { |badge| [badge[:program], badge[:review_id]] }
  end

  def self.linked_badges(text)
    return [] unless text.match?(%r{github\.com/(?:pyopensci|ropensci)/}i)

    pairs = text.scan(%r{\[!\[[^\]]*\]\((https?://[^\s)]+)\)\]\((https?://[^\s)]+)\)}i)
    if text.match?(/<img\b/i)
      Nokogiri::HTML.fragment(text).css("a[href] img[src]").each do |image|
        pairs << [image["src"], image.ancestors("a").first["href"]]
      end
    end
    pairs.concat(text.scan(%r{\.\.\s+(?:\|[^|]+\|\s+)?image::\s*(https?://\S+)\s*\n\s+:target:\s*(https?://\S+)}i))
    pairs.filter_map do |badge_url, target|
      match = target.match(%r{\Ahttps?://github\.com/(pyopensci|ropensci)/(?:software-review|software-submission|onboarding)/issues/([1-9]\d*)(?:[/?#].*)?\z}i)
      next unless match

      { program: match[1].casecmp?("pyopensci") ? "pyOpenSci" : "rOpenSci",
        badge_url: badge_url, review_id: match[2], review_url: target }
    end
  end
end
