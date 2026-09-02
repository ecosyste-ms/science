module Project::Scoring
  extend ActiveSupport::Concern

  CITATION_RESCORE_DEFAULT_LIMIT = 250
  CITATION_RESCORE_MAX_LIMIT = 1_000
  CITATION_FORMAT_SQL = <<~SQL.squish.freeze
    science_score_breakdown #>> '{breakdown,has_citation_file,format}'
  SQL
  REPOSITORY_BASENAME_SQL = <<~SQL.squish.freeze
    LOWER(
      regexp_replace(
        regexp_replace(
          COALESCE(NULLIF(repository ->> 'full_name', ''), url, ''),
          '/+$',
          ''
        ),
        '^.*/',
        ''
      )
    )
  SQL
  OVERLAPPING_SCIENCE_SIGNAL_SQL = <<~SQL.squish.freeze
    (
      (
        science_score_breakdown #>>
          '{breakdown,has_academic_links,details}' = 'Links to: zenodo.org'
        AND COALESCE(
          NULLIF(
            science_score_breakdown #>>
              '{breakdown,has_doi_in_readme,archive_dois}',
            ''
          ),
          '0'
        )::integer > 0
      )
      OR
      (
        COALESCE(
          science_score_breakdown #>>
            '{breakdown,negative_indicators,details}',
          ''
        ) !~ 'name:(homework|numbered-assignment|course-assignment)'
        AND
        (
          #{REPOSITORY_BASENAME_SQL} ~ '(^|[-_])homework([-_0-9]|$)'
          OR #{REPOSITORY_BASENAME_SQL} ~ '(^|[-_])assignment[-_]?[0-9]'
          OR (
            #{REPOSITORY_BASENAME_SQL} ~
              '(^|[-_])[a-z]{2,6}[0-9]{3,4}([-_]|$)'
            AND #{REPOSITORY_BASENAME_SQL} ~
              '(^|[-_])assignment([-_]|$)'
          )
        )
      )
    )
  SQL

  class_methods do
    def rescore_citations(
      limit: CITATION_RESCORE_DEFAULT_LIMIT,
      after_id: 0
    )
      scope = visible
        .where("NULLIF(citation_file, '') IS NOT NULL")
        .where("#{CITATION_FORMAT_SQL} IS NULL")
      rescore_science_score_scope(
        scope,
        limit: limit,
        after_id: after_id,
        failure_label: "Citation score"
      )
    end

    def rescore_overlapping_science_signals(
      limit: CITATION_RESCORE_DEFAULT_LIMIT,
      after_id: 0
    )
      scope = visible
        .where("joss_metadata IS NULL OR joss_metadata::text = '{}'")
        .where(OVERLAPPING_SCIENCE_SIGNAL_SQL)
      rescore_science_score_scope(
        scope,
        limit: limit,
        after_id: after_id,
        failure_label: "Overlapping science signal score"
      )
    end

    def rescore_science_score_scope(scope, limit:, after_id:, failure_label:)
      limit = Integer(limit, exception: false)
      after_id = Integer(after_id, exception: false)
      unless limit&.between?(1, CITATION_RESCORE_MAX_LIMIT)
        raise ArgumentError,
          "limit must be between 1 and #{CITATION_RESCORE_MAX_LIMIT}"
      end
      unless after_id && after_id >= 0
        raise ArgumentError, "after_id must be zero or greater"
      end

      project_ids = scope
        .where("projects.id > ?", after_id)
        .order(:id)
        .limit(limit)
        .pluck(:id)
      result = {
        selected: project_ids.length,
        updated: 0,
        failed: 0,
        last_id: project_ids.last,
      }

      project_ids.each do |project_id|
        project = find_by(id: project_id)
        next unless project

        if project.update_science_score
          result[:updated] += 1
        else
          result[:failed] += 1
          Rails.logger.error(
            "#{failure_label} update failed for project #{project.id}: " \
              "#{project.errors.full_messages.join(', ')}"
          )
        end
      rescue StandardError => error
        result[:failed] += 1
        Rails.logger.error(
          "#{failure_label} update failed for project #{project_id}: " \
            "#{error.class}: #{error.message}"
        )
      end

      result
    end

    def calculate_idf(projects)
      return [] if projects.empty?

      # Prepare documents from projects
      documents = projects.map do |project|
        text_parts = []
        text_parts << project.name if project.name.present?
        text_parts << project.description if project.description.present?
        text_parts << project.preprocessed_readme if project.readme.present?
        text = text_parts.join(' ')

        # Remove stopwords
        filter = Stopwords::Snowball::Filter.new('en')
        filtered_text = filter.filter(text.downcase.split).join(' ')

        TfIdfSimilarity::Document.new(filtered_text)
      end

      # Create model
      model = TfIdfSimilarity::TfIdfModel.new(documents)

      # Get all terms from all documents
      all_terms = documents.flat_map(&:terms).uniq

      # Calculate IDF for each term
      idf_scores = {}
      all_terms.each do |term|
        idf_scores[term] = model.idf(term)
      end

      # Sort by IDF score (descending) and return as array of hashes
      idf_scores.sort_by { |_, score| -score }.map do |term, score|
        { term: term, score: score }
      end
    end
  end

  def update_score
    update_attribute :score, score_parts.sum
  end

  def update_science_score
    result = calculate_science_score_breakdown
    update(science_score: result[:score], science_score_breakdown: result)
  end

  def science_score_breakdown
    # Return stored breakdown from database
    # This method should only be called from views/API, never calculate on the fly
    breakdown = read_attribute(:science_score_breakdown)
    breakdown&.with_indifferent_access
  end

  def calculate_science_score_breakdown
    calculator = ScienceScoreCalculator.new(self)
    calculator.calculate
  end

  def joss_vocabulary_analysis
    JossVocabularyAnalyzer.analyze_project(self)
  end

  def joss_vocabulary_score
    joss_vocabulary_analysis[:score]
  end

  def score_parts
    [
      repository_score,
      packages_score,
      commits_score,
      dependencies_score,
      events_score
    ]
  end

  def repository_score
    return 0 unless repository.present?
    Math.log [
      (repository['stargazers_count'] || 0),
      (repository['open_issues_count'] || 0)
    ].sum
  end

  def packages_score
    return 0 unless packages.present?
    Math.log [
      packages.map{|p| p["downloads"] || 0 }.sum,
      packages.map{|p| p["dependent_packages_count"] || 0 }.sum,
      packages.map{|p| p["dependent_repos_count"] || 0 }.sum,
      packages.map{|p| p["docker_downloads_count"] || 0 }.sum,
      packages.map{|p| p["docker_dependents_count"] || 0 }.sum,
      packages.map{|p| p['maintainers'].map{|m| m['uuid'] } }.flatten.uniq.length
    ].sum
  end

  def commits_score
    return 0 unless commits.present?
    Math.log [
      (commits['total_committers'] || 0),
    ].sum
  end

  def dependencies_score
    return 0 unless dependencies.present?
    0
  end

  def events_score
    return 0 unless events.present?
    0
  end

  def calculate_idf
    # Use the class method with an array containing just this project
    self.class.calculate_idf([self])
  end

  def preprocessed_readme
    return '' unless readme.present?
    
    begin
      html_content = GitHub::Markup.render(readme_file_name, readme.force_encoding("UTF-8"))
      
      # Extract text from HTML
      text = Nokogiri::HTML(html_content).text.strip.downcase
      # remove URLs
      text = text.gsub(/https?:\/\/[^\s]+/, '')
      # normalize whitespace
      text.gsub(/\s+/, ' ')
    rescue => e
      puts "Error preprocessing readme for #{repository_url}"
      p e.message
      p e.backtrace
      # Return empty string if any error occurs during rendering or processing
      ''
    end
  end
end
