require "csv"

class OpenAlexValidationReport
  BATCH_SIZE = 100
  SOURCE_PRIORITY = {
    OpenAlexProjectTopicImporter::JOSS_SOURCE => 0,
    OpenAlexProjectTopicImporter::README_DOI_SOURCE => 1,
    OpenAlexProjectTopicImporter::README_ARXIV_SOURCE => 2,
  }.freeze
  SCORE_BANDS = [
    ["<0.50", 0.5],
    ["0.50-0.79", 0.8],
    ["0.80-0.94", 0.95],
    [">=0.95", Float::INFINITY],
  ].freeze
  MATCH_METRICS = %i[
    exact_topic_matches top_5_topic_matches exact_subfield_matches
    top_5_subfield_matches exact_field_matches top_5_field_matches
    exact_domain_matches
  ].freeze
  SUMMARY_METRICS = {
    topic_top_1: :exact_topic_matches,
    topic_top_5: :top_5_topic_matches,
    subfield_top_1: :exact_subfield_matches,
    subfield_top_5: :top_5_subfield_matches,
    field_top_1: :exact_field_matches,
    field_top_5: :top_5_field_matches,
    domain_top_1: :exact_domain_matches,
  }.freeze
  HEADER = %w[
    project_id project_url project_name sources source_identifiers
    openalex_work_id label_score label_topic_id label_topic
    label_subfield_id label_subfield label_field_id label_field
    label_domain_id label_domain work_topic_ids work_subfield_ids
    work_field_ids work_domain_ids predicted_topic_id predicted_topic
    predicted_subfield_id predicted_subfield predicted_field_id predicted_field
    predicted_domain_id predicted_domain prediction_score prediction_terms
    top_topic_ids top_scores exact_topic_match top_5_topic_match
    exact_subfield_match top_5_subfield_match exact_field_match top_5_field_match
    exact_domain_match
  ].freeze

  attr_reader :classifier, :scope, :limit

  def initialize(classifier: OpenAlexTopicClassifier.new, scope: nil, limit: nil)
    @classifier = classifier
    @scope = scope || default_scope
    @limit = limit.to_i if limit.to_i.positive?
  end

  def generate(io: $stdout)
    result = {
      overall: empty_counts.merge(projects: 0, predicted_projects: 0),
      by_source: Hash.new { |hash, key| hash[key] = empty_counts },
      by_label_score: Hash.new { |hash, key| hash[key] = empty_counts },
    }
    io << CSV.generate_line(HEADER)

    report_scope.includes(project_open_alex_topics: :open_alex_topic)
      .find_each(batch_size: BATCH_SIZE) do |project|
        result[:overall][:projects] += 1
        predictions = classifier.classify_project(project, limit: 5)
        result[:overall][:predicted_projects] += 1 if predictions.any?

        labels_for(project).each do |assignments|
          primary_assignments = assignments.select(&:primary_topic?)
          assignment = preferred_assignment(primary_assignments)
          topics = assignments.map(&:open_alex_topic).uniq(&:id)
          matches = matches_for(predictions, topics)
          io << CSV.generate_line(row(project, assignments, assignment, predictions, matches))
          record_label(result[:overall], predictions, matches)
          record_label(result[:by_source][source_key(assignments)], predictions, matches)
          record_label(result[:by_label_score][score_band(assignment.score)], predictions, matches)
        end
      end

    result
  end

  def empty_counts
    {
      labels: 0,
      predicted_labels: 0,
      exact_topic_matches: 0,
      top_5_topic_matches: 0,
      exact_subfield_matches: 0,
      top_5_subfield_matches: 0,
      exact_field_matches: 0,
      top_5_field_matches: 0,
      exact_domain_matches: 0,
    }
  end

  def record_label(counts, predictions, matches)
    counts[:labels] += 1
    counts[:predicted_labels] += 1 if predictions.any?
    MATCH_METRICS.each do |metric|
      counts[metric] += 1 if matches.fetch(metric)
    end
  end

  def source_key(assignments)
    sorted_sources(assignments).join("|")
  end

  def score_band(score)
    SCORE_BANDS.find { |_, upper_bound| score < upper_bound }.first
  end

  def summary_lines(result)
    overall = result.fetch(:overall)
    lines = [summary_line(
      "overall projects=#{overall[:projects]}",
      overall,
      predicted: overall[:predicted_projects],
      population: overall[:projects]
    )]
    result.fetch(:by_source).sort.each do |source, counts|
      lines << summary_line("source=#{source}", counts)
    end
    SCORE_BANDS.each do |band, _|
      counts = result.fetch(:by_label_score).fetch(band, nil)
      lines << summary_line("label_score #{band}", counts) if counts
    end
    lines
  end

  def summary_line(label, counts, predicted: counts[:predicted_labels], population: counts[:labels])
    parts = [
      "OpenAlex validation #{label}",
      "labels=#{counts[:labels]}",
      "coverage=#{percentage(predicted, population)}",
    ]
    SUMMARY_METRICS.each do |name, metric|
      parts << "#{name}=#{percentage(counts[metric], counts[:labels])}"
    end
    parts.join(" ")
  end

  def percentage(numerator, denominator)
    return "0.00%" if denominator.zero?

    format("%.2f%%", numerator.to_f / denominator * 100)
  end

  def default_scope
    Project.visible.where(
      id: ProjectOpenAlexTopic.primary.select(:project_id)
    )
  end

  def report_scope
    limit ? scope.limit(limit) : scope
  end

  def labels_for(project)
    project.project_open_alex_topics
      .group_by(&:openalex_work_id)
      .select { |_, assignments| assignments.any?(&:primary_topic?) }
      .sort_by { |work_id, _| work_id }
      .map(&:last)
  end

  def preferred_assignment(assignments)
    assignments.min_by do |assignment|
      [SOURCE_PRIORITY.fetch(assignment.source, SOURCE_PRIORITY.length), -assignment.score]
    end
  end

  def row(project, assignments, assignment, predictions, matches)
    topic = assignment.open_alex_topic
    work_topics = assignments.map(&:open_alex_topic).uniq(&:id)
    prediction = predictions.first
    predicted_topic = prediction&.topic
    [
      project.id,
      project.url,
      project.name,
      sorted_sources(assignments).join("|"),
      assignments.map(&:source_identifier).uniq.sort.join("|"),
      assignment.openalex_work_id,
      assignment.score,
      topic.openalex_id,
      topic.display_name,
      topic.subfield_id,
      topic.subfield_name,
      topic.field_id,
      topic.field_name,
      topic.domain_id,
      topic.domain_name,
      hierarchy_values(work_topics, :openalex_id),
      hierarchy_values(work_topics, :subfield_id),
      hierarchy_values(work_topics, :field_id),
      hierarchy_values(work_topics, :domain_id),
      predicted_topic&.openalex_id,
      predicted_topic&.display_name,
      predicted_topic&.subfield_id,
      predicted_topic&.subfield_name,
      predicted_topic&.field_id,
      predicted_topic&.field_name,
      predicted_topic&.domain_id,
      predicted_topic&.domain_name,
      prediction&.score,
      prediction&.matched_terms&.join("|"),
      predictions.map { |item| item.topic.openalex_id }.join("|"),
      predictions.map { |item| item.score.round(6) }.join("|"),
      matches[:exact_topic_matches],
      matches[:top_5_topic_matches],
      matches[:exact_subfield_matches],
      matches[:top_5_subfield_matches],
      matches[:exact_field_matches],
      matches[:top_5_field_matches],
      matches[:exact_domain_matches],
    ]
  end

  def sorted_sources(assignments)
    assignments.map(&:source).uniq.sort_by do |source|
      [SOURCE_PRIORITY.fetch(source, SOURCE_PRIORITY.length), source]
    end
  end

  def matches_for(predictions, labels)
    {
      exact_topic_matches: hierarchy_match?(predictions.first, labels, :openalex_id),
      top_5_topic_matches: predictions.any? { |prediction| hierarchy_match?(prediction, labels, :openalex_id) },
      exact_subfield_matches: hierarchy_match?(predictions.first, labels, :subfield_id),
      top_5_subfield_matches: predictions.any? { |prediction| hierarchy_match?(prediction, labels, :subfield_id) },
      exact_field_matches: hierarchy_match?(predictions.first, labels, :field_id),
      top_5_field_matches: predictions.any? { |prediction| hierarchy_match?(prediction, labels, :field_id) },
      exact_domain_matches: hierarchy_match?(predictions.first, labels, :domain_id),
    }
  end

  def hierarchy_match?(prediction, labels, attribute)
    return false unless prediction

    predicted_id = normalize_openalex_id(prediction.topic.public_send(attribute))
    labels.any? do |label|
      predicted_id == normalize_openalex_id(label.public_send(attribute))
    end
  end

  def hierarchy_values(topics, attribute)
    topics.map { |topic| topic.public_send(attribute) }
      .compact
      .uniq
      .sort
      .join("|")
  end

  def normalize_openalex_id(value)
    value.to_s.split("/").last.downcase
  end
end
