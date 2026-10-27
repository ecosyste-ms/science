require "uri"

class SearchSeedClues
  RULES = {
    name: %w[whitespace],
    repository_url: %w[schemeless_url], homepage_url: %w[schemeless_url],
    doi: %w[identifier], rrid: %w[identifier],
    wikidata: %w[identifier], biotools: %w[identifier],
    ascl: %w[ascl_prefix resolver], swmath: %w[swmath_prefix resolver],
  }.freeze

  SHARED_REPOSITORY_HOSTS = %w[github.com gitlab.com bitbucket.org codeberg.org].freeze
  HOST_PAGES = {
    "github.com" => %w[about collections enterprise events explore features issues login marketplace orgs pricing search settings sponsors topics trending],
    "gitlab.com" => %w[explore groups users search help dashboard],
    "bitbucket.org" => %w[account dashboard product repo],
    "codeberg.org" => %w[explore user org],
  }.freeze

  def self.non_specific_url?(value)
    uri = URI.parse(value)
    host = uri.host.to_s.downcase.delete_prefix("www.")
    return false unless SHARED_REPOSITORY_HOSTS.include?(host)

    path = uri.path.split("/").reject(&:empty?)
    path.length < 2 || HOST_PAGES.fetch(host).include?(path.first.downcase)
  rescue URI::InvalidURIError
    false
  end

  def self.variants(type, value)
    case type
    when "name"
      [[value.gsub(/\p{Space}+/, " ").strip, "whitespace", false]]
    when "repository_url", "homepage_url"
      [[value.sub(%r{\Ahttps?://}, ""), "schemeless_url", true]]
    when "doi", "rrid", "wikidata", "biotools"
      [[value, "identifier", false]]
    when "ascl"
      [["ascl:#{value}", "ascl_prefix", false], ["https://ascl.net/#{value}", "resolver", true]]
    when "swmath"
      [["swMATH:#{value}", "swmath_prefix", false], ["https://zbmath.org/software/#{value}", "resolver", true]]
    else
      raise ArgumentError, "unsupported seed type: #{type}"
    end
  end

  def self.populate(database)
    words = SearchSeedWords.new
    generic_names = File.readlines(Rails.root.join("config/search_seed_generic_names.txt"), chomp: true).to_set
    clue = database.prepare(<<~SQL)
      INSERT INTO clues (value, case_sensitive, ordinary_word, punctuation_only, non_specific_url, generic_name, word_evidence)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(value, case_sensitive) DO UPDATE SET
        non_specific_url = MAX(non_specific_url, excluded.non_specific_url),
        generic_name = MAX(generic_name, excluded.generic_name)
      RETURNING id
    SQL
    link = database.prepare("INSERT INTO clue_seeds (clue_id, seed_id, variant) VALUES (?, ?, ?)")
    database.execute("SELECT id, type, normalized_value FROM seeds ORDER BY id") do |id, type, value|
      variants(type, value).each do |literal, variant, case_sensitive|
        literal = literal.unicode_normalize(:nfc).downcase unless case_sensitive
        word_evidence = case_sensitive ? [] : words.evidence(literal)
        ordinary_word = word_evidence.any? ? 1 : nil
        punctuation_only = literal.match?(/[\p{L}\p{N}]/) ? 0 : 1
        non_specific_url = %w[repository_url homepage_url].include?(type) && non_specific_url?(value) ? 1 : 0
        generic_name = type == "name" && generic_names.include?(literal) ? 1 : 0
        clue_id = clue.execute(literal, case_sensitive ? 1 : 0, ordinary_word, punctuation_only,
          non_specific_url, generic_name, JSON.generate(word_evidence)).next.first
        link.execute(clue_id, id, variant)
      end
    end
    database.execute_batch(<<~SQL)
      UPDATE clues AS c SET shared_name =
        EXISTS (SELECT 1 FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
                JOIN name_collisions n ON n.normalized_value = s.normalized_value
                WHERE cs.clue_id = c.id AND s.type = 'name')
        OR (SELECT COUNT(DISTINCT s.project_id) FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
            WHERE cs.clue_id = c.id AND s.type = 'name') > 1
        OR (SELECT COUNT(DISTINCT s.package_entry_id) FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
            WHERE cs.clue_id = c.id AND s.type = 'name') > 1;
      UPDATE clues AS c SET short_name = length(c.value) < 3 AND
        EXISTS (SELECT 1 FROM clue_seeds cs JOIN seeds s ON s.id = cs.seed_id
                WHERE cs.clue_id = c.id AND s.type = 'name');
      UPDATE clues AS c SET suggested_start_year =
        (SELECT CASE WHEN COUNT(*) = COUNT(suggested_start_year) THEN MIN(suggested_start_year) END
         FROM clue_candidates WHERE clue_id = c.id);
      UPDATE clues SET ambiguous = shared_name OR COALESCE(ordinary_word, 0) = 1 OR short_name OR punctuation_only OR non_specific_url OR generic_name;
    SQL
  ensure
    clue&.close
    link&.close
  end
end
