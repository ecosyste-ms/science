require "uri"

class ResearchOrganizationDomainMatcher
  CACHE_DURATION = 1.day
  EMPTY_CACHE_DURATION = 5.minutes
  LABEL_PREFIXES = %w[univ- u- uni- tu- fh-].freeze
  LABEL_WORDS = %w[university college institute academia].freeze

  @cache_mutex = Mutex.new

  class << self
    def match(domain)
      normalized = normalize_domain(domain)
      return unless normalized

      labels = normalized.split(".")
      labels.each_index do |index|
        candidate = labels[index..].join(".")
        record = current_domains[candidate]
        return record.merge(input_domain: normalized) if record
      end

      label = labels.find { |value| LABEL_PREFIXES.any? { |prefix| value.start_with?(prefix) } }
      return heuristic_match(normalized, label, "label_prefix") if label

      label = labels.find { |value| LABEL_WORDS.include?(value) }
      return heuristic_match(normalized, label, "label_word") if label
    end

    def institutional?(domain)
      match(domain).present?
    end

    def domain_from_url(value)
      return if value.blank?

      text = value.to_s.strip
      uri = URI.parse(text.match?(/\Ahttps?:\/\//i) ? text : "https://#{text}")
      normalize_domain(uri.host)
    rescue URI::InvalidURIError
      normalize_domain(text.sub(/\Ahttps?:\/\//i, "").split("/").first)
    end

    def normalize_domain(domain)
      value = domain.to_s.strip.downcase.sub(/\Awww\./, "").sub(/\.\z/, "")
      return if value.blank? || value.include?("/") || value.include?("@")

      value
    end

    def reset_cache!
      @cache_mutex.synchronize do
        @current_domains = nil
        @cache_expires_at = nil
      end
    end

    def current_domains
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = @current_domains
      return cached if cached && now < @cache_expires_at

      @cache_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return @current_domains if @current_domains && now < @cache_expires_at

        rows = ResearchOrganizationDomain.active
          .pluck(
            :domain,
            :source,
            :external_id,
            :organization_name,
            :organization_types,
            :strength
          )

        @current_domains = build_lookup(rows).freeze
        duration = rows.any? ? CACHE_DURATION : EMPTY_CACHE_DURATION
        @cache_expires_at = now + duration
        @current_domains
      end
    end

    def build_lookup(rows)
      rows.each_with_object({}) do |(domain, source, external_id, name, types, strength), lookup|
        candidate = {
          domain: domain.downcase,
          source: source,
          external_id: external_id,
          organization_name: name,
          organization_types: Array(types),
          strength: strength.to_f,
        }
        existing = lookup[candidate[:domain]]
        lookup[candidate[:domain]] = candidate if better_match?(candidate, existing)
      end
    end

    def better_match?(candidate, existing)
      return true unless existing
      return true if candidate[:strength] > existing[:strength]

      candidate[:strength] == existing[:strength] && candidate[:source] == "ror" && existing[:source] != "ror"
    end

    def heuristic_match(domain, label, rule)
      {
        domain: domain,
        input_domain: domain,
        source: "heuristic",
        external_id: "#{rule}:#{label}",
        organization_name: nil,
        organization_types: [],
        strength: 1.0,
      }
    end
  end
end
