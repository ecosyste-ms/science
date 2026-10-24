class SearchSeedClues
  RULES = {
    name: %w[whitespace],
    repository_url: %w[schemeless_url], homepage_url: %w[schemeless_url],
    doi: %w[identifier], rrid: %w[identifier],
    wikidata: %w[identifier], biotools: %w[identifier],
    ascl: %w[ascl_prefix resolver], swmath: %w[swmath_prefix resolver],
  }.freeze

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
    words = File.read(Rails.root.join("config/search_seed_common_words.txt")).split
    clue = database.prepare(<<~SQL)
      INSERT INTO clues (value, case_sensitive, ordinary_word)
      VALUES (?, ?, ?)
      ON CONFLICT(value, case_sensitive) DO UPDATE SET value = excluded.value
      RETURNING id
    SQL
    link = database.prepare("INSERT INTO clue_seeds (clue_id, seed_id, variant) VALUES (?, ?, ?)")
    database.execute("SELECT id, type, normalized_value FROM seeds ORDER BY id") do |id, type, value|
      variants(type, value).each do |literal, variant, case_sensitive|
        literal = literal.unicode_normalize(:nfc).downcase unless case_sensitive
        ordinary_word = !case_sensitive && words.include?(literal) ? 1 : nil
        clue_id = clue.execute(literal, case_sensitive ? 1 : 0, ordinary_word).next.first
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
      UPDATE clues SET ambiguous = shared_name OR COALESCE(ordinary_word, 0) = 1 OR short_name;
    SQL
  ensure
    clue&.close
    link&.close
  end
end
