require "test_helper"
require Rails.root.join("script/analyze_openalex_validation")

class AnalyzeOpenAlexValidationTest < ActiveSupport::TestCase
  HEADERS = %w[
    project_id project_url sources source_identifiers label_score label_field
    label_domain predicted_topic_id predicted_field predicted_domain
    prediction_score prediction_terms
    exact_topic_match top_5_topic_match exact_subfield_match
    top_5_subfield_match exact_field_match top_5_field_match
    exact_domain_match
  ].freeze

  test "reports project, source, score, and confusion metrics" do
    rows = [
      validation_row(
        project_id: 1,
        sources: "joss_doi|readme_doi",
        label_field: "Physics\nand Astronomy",
        label_domain: "Physical Sciences",
        predicted_field: "Physics",
        predicted_domain: "Physical Sciences",
        label_score: 0.98,
        prediction_score: 0.12,
        matches: true
      ),
      validation_row(
        project_id: 1,
        sources: "readme_doi",
        label_field: "Medicine",
        label_domain: "Health Sciences",
        predicted_field: "Physics",
        predicted_domain: "Physical Sciences",
        label_score: 0.75,
        prediction_score: 0.12,
        matches: false
      ),
      validation_row(
        project_id: 2,
        sources: "readme_arxiv",
        label_field: "Computer Science",
        label_domain: "Physical Sciences",
        predicted_field: nil,
        predicted_domain: nil,
        predicted_topic_id: nil,
        label_score: 0.4,
        prediction_score: 0,
        matches: false
      ),
      validation_row(
        project_id: 1,
        sources: "readme_doi",
        label_field: "Medicine",
        label_domain: "Health Sciences",
        predicted_field: "Physics",
        predicted_domain: "Physical Sciences",
        label_score: 0.7,
        prediction_score: 0.05,
        matches: false
      ),
    ]
    output = StringIO.new

    Tempfile.create(["openalex-validation", ".csv"]) do |file|
      file.puts "[INFO] AppSignal startup"
      file.write(CSV.generate_line(HEADERS))
      file.write(CSV.generate_line(HEADERS.map { |header| rows.first[header] }))
      file.puts "\e[1;34mINFO \e[0m pid=1 tid=abc: Sidekiq 8.1 connecting to Redis with options {url: \"redis://example\"}"
      rows.drop(1).each do |row|
        file.write(CSV.generate_line(HEADERS.map { |header| row[header] }))
      end
      file.puts "OpenAlex validation overall projects=2 labels=4"
      file.rewind

      OpenAlexValidationAnalyzer.new(file.path, output: output).run
    end

    report = output.string
    assert_includes report, "group=overall labels=4 coverage=75.00%"
    assert_includes report, "projects=2 coverage=50.00% one_label=50.00% one_field=50.00%"
    assert_includes report, "group=readme_doi labels=3 coverage=100.00%"
    assert_includes report, "group=readme_arxiv labels=1 coverage=0.00%"
    assert_includes report, "group=>=0.95 labels=1 coverage=100.00%"
    assert_includes report, "group=>=0.10 labels=2 coverage=100.00%"
    assert_includes report, 'count=2 label="Medicine" predicted="Physics"'
    assert_includes report, 'count=2 label="Health Sciences" predicted="Physical Sciences"'
    assert_includes report,
      'project_id=1 url="https://github.com/test/project-1" sources="readme_doi"'
    assert_includes report, 'source_identifiers="10.1000/project-1"'
    assert_includes report, 'prediction_score=0.1200 terms="physics|analysis"'
    assert_equal 2,
      report.scan('project_id=1 url="https://github.com/test/project-1"').length
  end

  test "rejects files without a validation header" do
    file = Tempfile.new(["openalex-validation", ".csv"])
    file.puts "not validation output"
    file.close

    error = assert_raises(ArgumentError) do
      OpenAlexValidationAnalyzer.new(file.path).run
    end

    assert_match(/Could not find the validation CSV header/, error.message)
  ensure
    file&.unlink
  end

  test "accepts a clean CSV without appended summary lines" do
    row = validation_row(
      project_id: 1,
      sources: "joss_doi",
      label_field: "Physics",
      label_domain: "Physical Sciences",
      predicted_field: "Physics",
      predicted_domain: "Physical Sciences",
      label_score: 0.98,
      prediction_score: 0.12,
      matches: true
    )
    output = StringIO.new

    Tempfile.create(["openalex-validation", ".csv"]) do |file|
      file.write(CSV.generate_line(HEADERS))
      file.write(CSV.generate_line(HEADERS.map { |header| row[header] }))
      file.rewind

      OpenAlexValidationAnalyzer.new(file.path, output: output).run
    end

    assert_includes output.string, "group=overall labels=1 coverage=100.00%"
  end

  def validation_row(
    project_id:,
    sources:,
    label_field:,
    label_domain:,
    predicted_field:,
    predicted_domain:,
    label_score:,
    prediction_score:,
    matches:,
    predicted_topic_id: "T1"
  )
    {
      "project_id" => project_id,
      "project_url" => "https://github.com/test/project-#{project_id}",
      "sources" => sources,
      "source_identifiers" => "10.1000/project-#{project_id}",
      "label_score" => label_score,
      "label_field" => label_field,
      "label_domain" => label_domain,
      "predicted_topic_id" => predicted_topic_id,
      "predicted_field" => predicted_field,
      "predicted_domain" => predicted_domain,
      "prediction_score" => prediction_score,
      "prediction_terms" => "physics|analysis",
      "exact_topic_match" => matches,
      "top_5_topic_match" => matches,
      "exact_subfield_match" => matches,
      "top_5_subfield_match" => matches,
      "exact_field_match" => matches,
      "top_5_field_match" => matches,
      "exact_domain_match" => matches,
    }.transform_values(&:to_s)
  end
end
