#!/usr/bin/env ruby

require "csv"
require "set"
require "tempfile"

class OpenAlexValidationAnalyzer
  CONFUSION_LIMIT = 20
  EXAMPLES_PER_CONFUSION = 3
  METRICS = {
    topic_top_1: "exact_topic_match",
    topic_top_5: "top_5_topic_match",
    subfield_top_1: "exact_subfield_match",
    subfield_top_5: "top_5_subfield_match",
    field_top_1: "exact_field_match",
    field_top_5: "top_5_field_match",
    domain_top_1: "exact_domain_match",
  }.freeze
  REQUIRED_COLUMNS = (
    %w[
      project_id project_url sources source_identifiers label_score label_field
      label_domain predicted_topic_id predicted_field predicted_domain
      prediction_score prediction_terms
    ] + METRICS.values
  ).freeze
  LABEL_SCORE_BANDS = [
    ["<0.50", 0...0.5],
    ["0.50-0.79", 0.5...0.8],
    ["0.80-0.94", 0.8...0.95],
    [">=0.95", 0.95..Float::INFINITY],
  ].freeze
  PREDICTION_SCORE_BANDS = [
    ["<0.01", 0...0.01],
    ["0.01-0.024", 0.01...0.025],
    ["0.025-0.049", 0.025...0.05],
    ["0.05-0.099", 0.05...0.1],
    [">=0.10", 0.1..Float::INFINITY],
  ].freeze

  attr_reader :path, :output

  def initialize(path, output: $stdout)
    @path = path
    @output = output
    @overall = new_stats
    @projects = {}
    @source_stats = Hash.new { |hash, key| hash[key] = new_stats }
    @label_score_stats = score_stats(LABEL_SCORE_BANDS)
    @prediction_score_stats = score_stats(PREDICTION_SCORE_BANDS)
    @field_stats = Hash.new { |hash, key| hash[key] = new_stats }
    @field_confusions = Hash.new(0)
    @domain_confusions = Hash.new(0)
    @field_confusion_examples = Hash.new { |hash, key| hash[key] = [] }
    @domain_confusion_examples = Hash.new { |hash, key| hash[key] = [] }
  end

  def run
    each_validation_row { |row| add(row) }
    verify_label_count
    write_report
  end

  def each_validation_row
    sanitized_validation_csv do |file|
      headers = CSV.parse_line(file.readline)
      missing_columns = REQUIRED_COLUMNS - headers
      if missing_columns.any?
        raise ArgumentError,
          "Missing validation columns: #{missing_columns.join(', ')}"
      end

      file.rewind
      CSV.new(file, headers: true).each { |row| yield row }
    end
  end

  def sanitized_validation_csv
    Tempfile.create(["openalex-validation", ".csv"]) do |sanitized|
      header_found = false
      File.foreach(path) do |line|
        unless header_found
          if line.start_with?("project_id,")
            sanitized.write(line)
            header_found = true
          end
          next
        end

        if line.start_with?("OpenAlex validation overall ")
          @reported_labels = line[/\blabels=(\d+)/, 1]&.to_i
          break
        end
        next if runtime_log_line?(line)

        sanitized.write(line)
      end
      unless header_found
        raise ArgumentError, "Could not find the validation CSV header in #{path}"
      end

      sanitized.rewind
      yield sanitized
    end
  end

  def runtime_log_line?(line)
    plain_line = line.gsub(/\e\[[\d;]*m/, "")
    plain_line.match?(
      /\AINFO\s+pid=.*\bSidekiq\b.*connecting to Redis with options/
    )
  end

  def verify_label_count
    return unless @reported_labels
    return if @overall[:labels] == @reported_labels

    raise ArgumentError,
      "Parsed #{@overall[:labels]} labels; validation summary reports #{@reported_labels}"
  end

  def add(row)
    update_stats(@overall, row)
    update_project(row)
    row["sources"].to_s.split("|").uniq.each do |source|
      update_stats(@source_stats[source], row)
    end
    update_stats(score_band(@label_score_stats, row["label_score"]), row)
    update_stats(
      score_band(@prediction_score_stats, row["prediction_score"]),
      row
    )
    update_stats(@field_stats[row["label_field"]], row)
    unless true_value?(row["exact_field_match"])
      add_confusion(
        @field_confusions,
        @field_confusion_examples,
        [row["label_field"], row["predicted_field"]],
        row
      )
    end
    unless true_value?(row["exact_domain_match"])
      add_confusion(
        @domain_confusions,
        @domain_confusion_examples,
        [row["label_domain"], row["predicted_domain"]],
        row
      )
    end
  end

  def add_confusion(counts, examples, pair, row)
    counts[pair] += 1
    sample = {
      project_id: row["project_id"],
      project_url: row["project_url"],
      sources: row["sources"],
      source_identifiers: row["source_identifiers"],
      label_score: row["label_score"].to_f,
      prediction_score: row["prediction_score"].to_f,
      prediction_terms: row["prediction_terms"],
    }
    samples = examples[pair]
    existing = samples.index do |candidate|
      candidate[:project_id] == sample[:project_id]
    end
    if existing && (example_rank(sample) <=> example_rank(samples[existing])).positive?
      samples[existing] = sample
    end
    samples << sample unless existing
    samples.sort_by! do |candidate|
      [-candidate[:prediction_score], -candidate[:label_score], candidate[:project_id].to_i]
    end
    samples.slice!(EXAMPLES_PER_CONFUSION, samples.length)
  end

  def example_rank(sample)
    [sample[:prediction_score], sample[:label_score]]
  end

  def update_project(row)
    project = @projects[row["project_id"]] ||= {
      labels: 0,
      covered: false,
      fields: Set.new,
      domains: Set.new,
      metrics: Hash.new(false),
    }
    project[:labels] += 1
    project[:covered] ||= value_present?(row["predicted_topic_id"])
    project[:fields] << row["label_field"] if value_present?(row["label_field"])
    project[:domains] << row["label_domain"] if value_present?(row["label_domain"])
    METRICS.each do |name, column|
      project[:metrics][name] ||= true_value?(row[column])
    end
  end

  def new_stats
    { labels: 0, covered: 0, metrics: Hash.new(0) }
  end

  def score_stats(bands)
    bands.to_h { |label, range| [label, [range, new_stats]] }
  end

  def score_band(stats, value)
    score = value.to_f
    _, entry = stats.find { |_, (range, _)| range.cover?(score) }
    entry.last
  end

  def update_stats(stats, row)
    stats[:labels] += 1
    stats[:covered] += 1 if value_present?(row["predicted_topic_id"])
    METRICS.each do |name, column|
      stats[:metrics][name] += 1 if true_value?(row[column])
    end
  end

  def true_value?(value)
    value == "true"
  end

  def value_present?(value)
    !value.nil? && !value.empty?
  end

  def percentage(numerator, denominator)
    return "0.00%" if denominator.zero?

    format("%.2f%%", numerator.to_f / denominator * 100)
  end

  def write_report
    output.puts "Overall label agreement"
    output.puts stats_line("overall", @overall)
    output.puts
    write_project_report
    output.puts
    write_group("Individual source membership", @source_stats)
    output.puts
    write_score_group("OpenAlex label score bands", @label_score_stats)
    output.puts
    write_score_group("Classifier prediction score bands", @prediction_score_stats)
    output.puts
    write_group("Label field agreement", @field_stats)
    output.puts
    write_confusions(
      "Top field confusion pairs",
      @field_confusions,
      @field_confusion_examples
    )
    output.puts
    write_confusions(
      "Top domain confusion pairs",
      @domain_confusions,
      @domain_confusion_examples
    )
  end

  def write_project_report
    projects = @projects.values
    total = projects.length
    one_label = projects.count { |project| project[:labels] == 1 }
    one_field = projects.count { |project| project[:fields].length == 1 }
    one_domain = projects.count { |project| project[:domains].length == 1 }
    covered = projects.count { |project| project[:covered] }

    output.puts "Project-level any-label agreement"
    output.puts [
      "projects=#{total}",
      "coverage=#{percentage(covered, total)}",
      "one_label=#{percentage(one_label, total)}",
      "one_field=#{percentage(one_field, total)}",
      "one_domain=#{percentage(one_domain, total)}",
      *METRICS.keys.map do |metric|
        matches = projects.count { |project| project[:metrics][metric] }
        "#{metric}=#{percentage(matches, total)}"
      end,
    ].join(" ")
  end

  def write_group(title, stats)
    output.puts title
    stats.sort_by { |name, values| [-values[:labels], name.to_s] }
      .each do |name, values|
        output.puts stats_line(name || "(none)", values)
      end
  end

  def write_score_group(title, stats)
    output.puts title
    stats.each do |label, (_, values)|
      output.puts stats_line(label, values)
    end
  end

  def stats_line(name, stats)
    [
      "group=#{name}",
      "labels=#{stats[:labels]}",
      "coverage=#{percentage(stats[:covered], stats[:labels])}",
      *METRICS.keys.map do |metric|
        "#{metric}=#{percentage(stats[:metrics][metric], stats[:labels])}"
      end,
    ].join(" ")
  end

  def write_confusions(title, confusions, examples)
    output.puts title
    confusions.sort_by { |pair, count| [-count, pair.map(&:to_s)] }
      .first(CONFUSION_LIMIT)
      .each do |(label, predicted), count|
        output.puts [
          "count=#{count}",
          "label=#{(label || '(none)').inspect}",
          "predicted=#{(predicted || '(none)').inspect}",
        ].join(" ")
        examples[[label, predicted]].each do |sample|
          output.puts [
            "  project_id=#{sample[:project_id]}",
            "url=#{sample[:project_url].inspect}",
            "sources=#{sample[:sources].inspect}",
            "source_identifiers=#{sample[:source_identifiers].inspect}",
            "label_score=#{format('%.4f', sample[:label_score])}",
            "prediction_score=#{format('%.4f', sample[:prediction_score])}",
            "terms=#{sample[:prediction_terms].inspect}",
          ].join(" ")
        end
      end
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.one?
    warn "Usage: ruby script/analyze_openalex_validation.rb VALIDATION_CSV"
    exit 1
  end

  OpenAlexValidationAnalyzer.new(ARGV.first).run
end
