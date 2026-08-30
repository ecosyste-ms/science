class OpenAlexTopicClassifier
  DEFAULT_LIMIT = 5
  MATCHED_TERM_LIMIT = 10
  FIELD_TOPIC_LIMIT = 5
  SOURCE_WEIGHTS = {
    topic_name: 5.0,
    topic_keyword: 4.0,
    subfield_name: 2.0,
    field_name: 1.0,
    topic_description: 1.0,
    project_name: 5.0,
    project_keyword: 5.0,
    project_description: 4.0,
    project_readme: 1.0,
  }.freeze
  STOP_WORDS = %w[
    a about after an and are as at be before between by can could did do does
    during each for from had has have how if in into is it its may more most
    of on or other our over should than that the their these this those through
    to under using was we were what when where which while who will with would
  ].to_h { |word| [word, true] }.freeze
  GENERIC_TERMS = %w[
    analysis application applications code data github gitlab library method methods
    model models open open_source package packages project projects python research
    scientific software source source_software study studies system systems tool
    toolkit tools version
  ].to_h { |term| [term, true] }.freeze

  Prediction = Struct.new(:topic, :score, :matched_terms, keyword_init: true)
  FieldPrediction = Struct.new(
    :field_id,
    :field_name,
    :domain_id,
    :domain_name,
    :score,
    :matched_terms,
    :topic_ids,
    keyword_init: true
  )

  attr_reader :topics, :topic_lookup, :topic_terms, :topic_norms, :term_index

  def initialize(scope: OpenAlexTopic.active)
    @topics = scope.to_a
    @topic_lookup = topics.index_by(&:id)
    @topic_terms = build_topic_terms
    document_frequency = build_document_frequency
    @topic_norms, @term_index = build_index(document_frequency)
  end

  def classify_project(project, limit: DEFAULT_LIMIT)
    project_terms = project_term_weights(project)
    return [] if project_terms.empty?

    project_norm = vector_norm(project_terms.values)
    scores = Hash.new(0.0)
    project_terms.each do |term, project_weight|
      term_index.fetch(term, []).each do |topic_id, topic_weight|
        scores[topic_id] += project_weight * topic_weight
      end
    end

    ranked_scores = scores.map do |topic_id, score|
      [topic_id, score / (project_norm * topic_norms.fetch(topic_id))]
    end.sort_by { |topic_id, score| [-score, topic_lookup.fetch(topic_id).openalex_id] }
    ranked_scores = ranked_scores.first(limit) if limit

    ranked_scores.map do |topic_id, score|
      Prediction.new(
        topic: topic_lookup.fetch(topic_id),
        score: score,
        matched_terms: matched_terms(topic_id, project_terms)
      )
    end
  end

  def classify_project_fields(project, limit: DEFAULT_LIMIT)
    fields = {}

    classify_project(project, limit: DEFAULT_LIMIT).each do |prediction|
      topic = prediction.topic
      field = fields[topic.field_id] ||= FieldPrediction.new(
        field_id: topic.field_id,
        field_name: topic.field_name,
        domain_id: topic.domain_id,
        domain_name: topic.domain_name,
        score: prediction.score,
        matched_terms: [],
        topic_ids: []
      )
      field.matched_terms = (field.matched_terms + prediction.matched_terms)
        .uniq.first(MATCHED_TERM_LIMIT)
      field.topic_ids = (field.topic_ids + [topic.openalex_id])
        .first(FIELD_TOPIC_LIMIT)
    end

    fields.values
      .sort_by { |field| [-field.score, field.field_id] }
      .first(limit)
  end

  def build_topic_terms
    topics.to_h do |topic|
      weights = Hash.new(0.0)
      add_terms(weights, topic.display_name, SOURCE_WEIGHTS[:topic_name])
      add_terms(weights, topic.subfield_name, SOURCE_WEIGHTS[:subfield_name])
      add_terms(weights, topic.field_name, SOURCE_WEIGHTS[:field_name])
      add_terms(weights, topic.description, SOURCE_WEIGHTS[:topic_description])
      Array(topic.keywords).each do |keyword|
        add_terms(weights, keyword, SOURCE_WEIGHTS[:topic_keyword])
      end
      [topic.id, weights]
    end
  end

  def build_document_frequency
    topic_terms.each_value.each_with_object(Hash.new(0)) do |weights, frequencies|
      weights.each_key { |term| frequencies[term] += 1 }
    end
  end

  def build_index(document_frequency)
    index = Hash.new { |hash, key| hash[key] = [] }
    norms = {}

    topic_terms.each do |topic_id, weights|
      weighted_terms = weights.to_h do |term, weight|
        frequency = document_frequency.fetch(term)
        inverse_frequency = Math.log((topics.length + 1.0) / (frequency + 1.0)) + 1.0
        [term, weight * inverse_frequency]
      end
      norms[topic_id] = vector_norm(weighted_terms.values)
      weighted_terms.each { |term, weight| index[term] << [topic_id, weight] }
      topic_terms[topic_id] = weighted_terms
    end

    [norms, index]
  end

  def project_term_weights(project)
    weights = Hash.new(0.0)
    add_terms(weights, project.name, SOURCE_WEIGHTS[:project_name])
    add_terms(weights, project.description, SOURCE_WEIGHTS[:project_description])
    add_terms(
      weights,
      JossVocabularyAnalyzer.sanitize_readme(project.readme),
      SOURCE_WEIGHTS[:project_readme]
    )
    Array(project.keywords).each do |keyword|
      add_terms(weights, keyword, SOURCE_WEIGHTS[:project_keyword])
    end
    weights
  end

  def add_terms(weights, text, weight)
    JossVocabularyAnalyzer.terms_from_text(text).each do |term|
      next if ignored_term?(term)

      weights[term] = [weights[term], weight].max
    end
  end

  def ignored_term?(term)
    STOP_WORDS.key?(term) || GENERIC_TERMS.key?(term) ||
      term.split("_").any? { |word| STOP_WORDS.key?(word) }
  end

  def matched_terms(topic_id, project_terms)
    topic_terms.fetch(topic_id).filter_map do |term, topic_weight|
      project_weight = project_terms[term]
      [term, project_weight * topic_weight] if project_weight
    end.sort_by { |term, contribution| [-contribution, term] }
      .first(MATCHED_TERM_LIMIT)
      .map(&:first)
  end

  def vector_norm(values)
    Math.sqrt(values.sum { |value| value * value })
  end
end
