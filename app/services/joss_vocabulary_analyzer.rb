class JossVocabularyAnalyzer
  TEXT_LIMIT = 5_000
  LENGTH_BOUNDS = [2_500, 4_000, 6_500, 10_500].freeze
  LABEL_LEAK_TERMS = %w[doi joss theoj].freeze
  GENERIC_DOCUMENTATION_WORD = /\A(?:docs?|documentation|readthedocs|versions?)\z/.freeze
  SKIPPED_HEADINGS = /\A(?:acknowledg|citat|cite\b|citing\b|how to cit|community guidelines?\b|contribut|documentation\b|docs?\b|install|licen[cs]e?\b|references?\b)/i
  JOSS_REFERENCE = /10\.21105|joss\.theoj|journal of open source software/i
  TEMPLATE_LABEL = /statement of need|community guidelines?/i
  MIN_JOSS_DOCUMENT_COUNT = 10
  MIN_ENRICHMENT_RATIO = 2.0
  MIN_SUPPORTING_FOLDS = 3
  FOLD_ENRICHMENT_RATIO = 1.5
  WEIGHT_SHRINKAGE = 10.0
  MAX_TERM_WEIGHT = 3.0
  TOP_TERMS = 3
  EVIDENCE_THRESHOLD = 3.0
  MODEL_CACHE_DURATION = 1.day
  EMPTY_MODEL_CACHE_DURATION = 5.minutes

  @model_mutex = Mutex.new

  class << self
    def analyze_project(project)
      snapshot = current_model
      return empty_analysis unless snapshot

      matched = tokens(project).filter_map do |term|
        weight = snapshot[:term_weights][term]
        [term, weight] if weight
      end
      matched = distinct_matches(matched).sort_by { |_, weight| -weight }.first(snapshot[:top_terms])

      evidence = matched.sum { |_, weight| weight }
      score = [evidence / snapshot[:evidence_threshold] * 30.0, 100.0].min
      {
        score: score.round(2),
        evidence: evidence.round(4),
        terms: matched.map(&:first),
        model_id: snapshot[:id]
      }
    end

    def score_project(project)
      analyze_project(project)[:score]
    end

    def distinct_matches(matches)
      parents = Array.new(matches.length) { |index| index }
      word_owners = {}

      matches.each_with_index do |(term, _), index|
        term.split("_").each do |word|
          owner = word_owners[word]
          if owner
            left = match_root(parents, index)
            right = match_root(parents, owner)
            parents[right] = left unless left == right
          else
            word_owners[word] = index
          end
        end
      end

      matches.each_with_index.each_with_object({}) do |(match, index), groups|
        root = match_root(parents, index)
        groups[root] = match if !groups.key?(root) || match.last > groups[root].last
      end.values
    end

    def match_root(parents, index)
      while parents[index] != index
        parents[index] = parents[parents[index]]
        index = parents[index]
      end
      index
    end

    def rebuild!(joss_scope: Project.with_joss, background_scope: Project.where(joss_metadata: nil).with_readme, &progress)
      attributes = build_model(joss_scope: joss_scope, background_scope: background_scope, progress: progress)
      record = JossVocabularyModel.create!(attributes)
      cache_model!(record)
      record
    end

    def build_model(joss_scope:, background_scope:, progress: nil)
      joss_counts, joss_project_count, joss_readme_count, fold_counts, fold_totals, joss_bin_totals =
        joss_document_frequencies(joss_scope)
      candidates = joss_counts.select { |_, count| count >= MIN_JOSS_DOCUMENT_COUNT }.keys.to_h { |term| [term, true] }
      background_bin_counts, background_bin_totals, background_project_count =
        background_frequencies(background_scope, candidates, progress: progress)

      ranked = joss_counts.filter_map do |term, joss_count|
        next if joss_count < MIN_JOSS_DOCUMENT_COUNT
        joss_rate = (joss_count + 0.5) / (joss_project_count + 1.0)
        background_rate = matched_background_rate(
          term,
          joss_bin_totals,
          background_bin_counts,
          background_bin_totals
        )
        next if background_rate.zero?
        ratio = joss_rate / background_rate
        next if ratio < MIN_ENRICHMENT_RATIO
        supporting_folds = fold_counts.each_index.count do |fold|
          fold_rate = (fold_counts[fold].fetch(term, 0) + 0.5) / (fold_totals[fold] + 1.0)
          fold_rate / background_rate >= FOLD_ENRICHMENT_RATIO
        end
        next if supporting_folds < MIN_SUPPORTING_FOLDS
        reliability = joss_count / (joss_count + WEIGHT_SHRINKAGE)
        weight = [Math.log(ratio) * reliability, MAX_TERM_WEIGHT].min
        [term, weight.round(6), joss_count, ratio.round(3), supporting_folds]
      end.sort_by { |_, weight, *| -weight }

      raise "JOSS vocabulary build produced no terms" if ranked.empty?

      {
        term_weights: ranked.to_h { |term, weight, *| [term, weight] },
        config: {
          version: 5,
          text_limit: TEXT_LIMIT,
          top_terms: TOP_TERMS,
          evidence_grouping: "shared_words",
          evidence_threshold: EVIDENCE_THRESHOLD,
          min_joss_document_count: MIN_JOSS_DOCUMENT_COUNT,
          min_enrichment_ratio: MIN_ENRICHMENT_RATIO,
          min_supporting_folds: MIN_SUPPORTING_FOLDS
        },
        source_counts: {
          joss_projects: joss_project_count,
          joss_projects_with_readmes: joss_readme_count,
          background_projects: background_project_count,
          vocabulary_terms: ranked.length
        },
        diagnostics: {
          top_terms: ranked.first(50).map do |term, weight, joss_count, ratio, supporting_folds|
            {
              term: term,
              weight: weight,
              joss_count: joss_count,
              ratio: ratio,
              supporting_folds: supporting_folds
            }
          end
        }
      }
    end

    def joss_document_frequencies(scope)
      counts = Hash.new(0)
      fold_counts = Array.new(4) { Hash.new(0) }
      fold_totals = Array.new(4, 0)
      joss_project_count = 0
      joss_readme_count = 0
      joss_bin_totals = Array.new(LENGTH_BOUNDS.length + 1, 0)

      vocabulary_scope(scope).find_each(batch_size: 500) do |project|
        fold = project.id % fold_counts.length
        tokens(project).each do |term|
          counts[term] += 1
          fold_counts[fold][term] += 1
        end
        fold_totals[fold] += 1
        joss_project_count += 1
        next if project.readme.nil?
        joss_readme_count += 1
        joss_bin_totals[length_bin(project.readme)] += 1
      end

      [counts, joss_project_count, joss_readme_count, fold_counts, fold_totals, joss_bin_totals]
    end

    def background_frequencies(scope, candidates, progress: nil)
      bin_counts = Array.new(LENGTH_BOUNDS.length + 1) { Hash.new(0) }
      bin_totals = Array.new(LENGTH_BOUNDS.length + 1, 0)
      processed = 0

      vocabulary_scope(scope).find_each(batch_size: 500) do |project|
        next if joss_reference?(project)
        bin = length_bin(project.readme)
        tokens(project).each do |term|
          bin_counts[bin][term] += 1 if candidates.key?(term)
        end
        bin_totals[bin] += 1
        processed += 1
        progress&.call("Processed #{processed} background projects") if (processed % 10_000).zero?
      end

      [bin_counts, bin_totals, processed]
    end

    def matched_background_rate(term, joss_bin_totals, background_bin_counts, background_bin_totals)
      available_bins = joss_bin_totals.each_index.select do |bin|
        joss_bin_totals[bin].positive? && background_bin_totals[bin].positive?
      end
      matched_joss_total = available_bins.sum { |bin| joss_bin_totals[bin] }
      return 0.0 if matched_joss_total.zero?

      available_bins.sum do |bin|
        bin_weight = joss_bin_totals[bin].to_f / matched_joss_total
        bin_rate = (background_bin_counts[bin].fetch(term, 0) + 0.5) / (background_bin_totals[bin] + 1.0)
        bin_weight * bin_rate
      end
    end

    def tokens(project)
      parts = [
        project.name,
        vocabulary_description(project),
        sanitize_readme(project.readme),
        *Array(project.keywords)
      ]
      parts.compact.flat_map { |part| terms_from_text(part) }.uniq
    end

    def terms_from_text(text)
      words = strip_label_artifacts(text).scrub(" ").unicode_normalize(:nfkc).downcase
        .scan(/[\p{L}][\p{L}\p{N}]{2,39}/u)
      terms = words.reject { |term| LABEL_LEAK_TERMS.include?(term) }
      pairs = words.each_cons(2).filter_map do |left, right|
        "#{left}_#{right}" unless LABEL_LEAK_TERMS.include?(left) || LABEL_LEAK_TERMS.include?(right)
      end
      (terms + pairs).reject { |term| generic_documentation_term?(term) }.uniq
    end

    def sanitize_readme(readme)
      in_fence = false
      lines = readme.to_s.scrub(" ").slice(0, TEXT_LIMIT).each_line.filter_map do |line|
        stripped = line.lstrip
        if stripped.start_with?("```", "~~~")
          in_fence = !in_fence
          next
        end
        next if in_fence
        next if line.match?(/\A(?: {4}|\t)/)
        next if line.match?(/!\[[^\]]*\]\([^)]*\)|<img\b|shields\.io/i)
        next if line.match?(/\A\s*\.\.\s+(?:image|figure)::/i)
        next if line.match?(/\A\s+:[\w-]+:/)
        next if line.match?(/\A\s*(?:[-*+]\s*)?@\p{L}+\s*\{/u)
        next if line.match?(JOSS_REFERENCE)
        line
      end

      body = []
      skipping_level = nil
      index = 0
      while index < lines.length
        heading = markdown_heading(lines, index)
        if heading
          level, title, consumed = heading
          skipping_level = nil if skipping_level && level <= skipping_level
          skipping_level = level if skipping_level.nil? && skipped_heading?(title)
          index += consumed
          next
        end

        body << lines[index] unless skipping_level
        index += 1
      end

      body.join.gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1')
        .gsub(%r{https?://\S+}, " ")
        .gsub(/<[^>]+>/, " ")
    end

    def generic_documentation_term?(term)
      term.split("_").any? { |word| word.match?(GENERIC_DOCUMENTATION_WORD) }
    end

    def markdown_heading(lines, index)
      line = lines[index]
      atx = line.match(/\A\s{0,3}(?<marks>\#{1,6})\s+(?<title>.+?)\s*\#*\s*\z/)
      return [atx[:marks].length, atx[:title], 1] if atx

      html = line.match(/\A\s*<h(?<level>[1-6])\b[^>]*>(?<title>.*?)<\/h\k<level>>\s*\z/i)
      return [html[:level].to_i, html[:title], 1] if html

      underline = lines[index + 1]&.match(/\A\s{0,3}(?<marks>=+|-+)\s*\z/)
      return unless underline && line.match?(/\p{L}/u)

      [underline[:marks].start_with?("=") ? 1 : 2, line.strip, 2]
    end

    def skipped_heading?(title)
      normalized = title.gsub(/<[^>]+>|[`*_\[\]()]/, " ").strip
        .sub(/\A(?:\d+[.)]\s*)?[^\p{L}]*/u, "")
      normalized.match?(SKIPPED_HEADINGS)
    end

    def joss_reference?(project)
      text = [vocabulary_description(project), project.readme.to_s.slice(0, TEXT_LIMIT)].compact.join(" ").scrub(" ")
      text.match?(JOSS_REFERENCE) || text.match?(/published in joss/i)
    end

    def strip_label_artifacts(text)
      text.to_s
        .gsub(/10\.21105\/[\w.()-]+/i, " ")
        .gsub(/journal of open source software/i, " ")
        .gsub(/published in joss/i, " ")
        .gsub(TEMPLATE_LABEL, " ")
    end

    def vocabulary_scope(scope)
      scope.select(:id, :url, :name, :keywords, :readme)
        .select("COALESCE(NULLIF(description, ''), repository ->> 'description') AS vocabulary_description")
    end

    def vocabulary_description(project)
      if project.has_attribute?(:vocabulary_description)
        project.read_attribute(:vocabulary_description)
      else
        project.description
      end
    end

    def length_bin(readme)
      length = readme.to_s.bytesize
      LENGTH_BOUNDS.index { |bound| length < bound } || LENGTH_BOUNDS.length
    end

    def current_model
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return @cached_model if model_cache_fresh?(now)

      @model_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return @cached_model if model_cache_fresh?(now)
        record = JossVocabularyModel.latest
        @cached_model = record ? model_snapshot(record) : nil
        @cache_checked_at = now
        @cached_model
      end
    rescue ActiveRecord::StatementInvalid => error
      Rails.logger.error("Unable to load JOSS vocabulary model: #{error.message}")
      nil
    end

    def model_cache_fresh?(now)
      return false unless @cache_checked_at

      duration = @cached_model ? MODEL_CACHE_DURATION : EMPTY_MODEL_CACHE_DURATION
      now - @cache_checked_at < duration
    end

    def model_snapshot(record)
      config = record.config.to_h
      {
        id: record.id,
        term_weights: record.term_weights.to_h.transform_values(&:to_f).freeze,
        top_terms: config.fetch("top_terms", TOP_TERMS).to_i,
        evidence_threshold: config.fetch("evidence_threshold", EVIDENCE_THRESHOLD).to_f
      }.freeze
    end

    def cache_model!(record)
      @model_mutex.synchronize do
        @cached_model = model_snapshot(record)
        @cache_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def reset_cache!
      @model_mutex.synchronize do
        @cached_model = nil
        @cache_checked_at = nil
      end
    end

    def empty_analysis
      { score: 0.0, evidence: 0.0, terms: [], model_id: nil }
    end
  end
end
