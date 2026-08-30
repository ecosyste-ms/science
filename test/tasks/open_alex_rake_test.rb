require "test_helper"
require "rake"

class OpenAlexRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("open_alex:sync")
    @previous_api_key = ENV["OPENALEX_API_KEY"]
    @previous_limit = ENV["LIMIT"]
    ENV["OPENALEX_API_KEY"] = "test-key"
  end

  teardown do
    ENV["OPENALEX_API_KEY"] = @previous_api_key
    ENV["LIMIT"] = @previous_limit
  end

  test "validation exports recomputed predictions through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/open-alex-validation-rake",
      name: "Algorithm Toolkit",
      description: "Software engineering algorithms",
      keywords: %w[algorithm software]
    )
    topic = OpenAlexTopic.create!(
      openalex_id: "https://openalex.org/T-validation-rake",
      display_name: "Software Engineering",
      description: "Research about software engineering algorithms",
      keywords: ["Software Engineering", "Algorithms"],
      subfield_id: "1712",
      subfield_name: "Software",
      field_id: "17",
      field_name: "Computer Science",
      domain_id: "3",
      domain_name: "Physical Sciences"
    )
    ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: topic,
      score: 0.98,
      primary_topic: true,
      source: "joss_doi",
      source_identifier: "10.1000/rake-validation",
      openalex_work_id: "https://openalex.org/W-validation-rake"
    )
    ENV["LIMIT"] = "1"

    output, errors = capture_io { Rake::Task["open_alex:validation"].execute }

    rows = CSV.parse(output, headers: true)
    assert_equal 1, rows.length
    assert_equal project.url, rows.first["project_url"]
    assert_equal topic.openalex_id, rows.first["predicted_topic_id"]
    assert_equal "Computer Science", rows.first["predicted_field"]
    assert_includes errors,
      "OpenAlex validation overall projects=1 labels=1 coverage=100.00% topic_top_1=100.00%"
    assert_includes errors, "OpenAlex validation source=joss_doi labels=1 coverage=100.00%"
    assert_includes errors, "OpenAlex validation label_score >=0.95 labels=1 coverage=100.00%"
    assert_empty project.project_fields.reload
  end

  test "field classification materializes ranked fields through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/open-alex-fields-rake",
      name: "Genome Climate Toolkit",
      description: "Genome sequencing with climate model inputs",
      keywords: %w[genomics sequencing climate],
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    OpenAlexTopic.create!(
      openalex_id: "https://openalex.org/T-genome-rake",
      display_name: "Genome Sequence Analysis",
      keywords: ["Genomics", "DNA Sequencing"],
      subfield_id: "1306",
      subfield_name: "Genetics",
      field_id: "13",
      field_name: "Biochemistry, Genetics and Molecular Biology",
      domain_id: "1",
      domain_name: "Life Sciences"
    )
    OpenAlexTopic.create!(
      openalex_id: "https://openalex.org/T-climate-rake",
      display_name: "Climate Modelling",
      keywords: ["Climate Models"],
      subfield_id: "2306",
      subfield_name: "Global and Planetary Change",
      field_id: "23",
      field_name: "Environmental Science",
      domain_id: "3",
      domain_name: "Physical Sciences"
    )

    output, = capture_io { Rake::Task["open_alex:classify_fields"].execute }

    assert_equal %w[13 23], project.reload.open_alex_fields_with_scores
      .map { |field, _| field.openalex_id }
    assert_includes output, "OpenAlex field projects classified: 1"
    assert_includes output, "fields: 2"
    assert_includes output, "classifications: 2"
  end

  test "sync imports JOSS, README, arXiv, and metadata labels through the rake entrypoint" do
    joss_project = Project.create!(
      url: "https://github.com/test/open-alex-rake",
      joss_metadata: { "doi" => "10.21105/joss.00001" }
    )
    linked_project = Project.create!(
      url: "https://github.com/test/open-alex-linked-rake",
      readme: <<~README,
        See DOI: 10.1000/linked.1
        Funder: https://doi.org/10.13039/501100011033
        ![DOI badge](https://img.shields.io/badge/DOI-10.5281/zenodo.4642814-informational?logo=data:image/svg+xml;base64,LONG)
      README
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    metadata_project = Project.create!(
      url: "https://github.com/test/open-alex-metadata-rake",
      citation_file: <<~BIBTEX,
        @article{metadata,
          doi = {10.1000/metadata.1}
        }
      BIBTEX
      codemeta: {
        "referencePublication" => "https://doi.org/10.1000/metadata.1",
      }.to_json,
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    arxiv_project = Project.create!(
      url: "https://github.com/test/open-alex-arxiv-rake",
      readme: "Paper: https://arxiv.org/abs/2202.01037v2?utm_source=readme",
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    arxiv_list_project = Project.create!(
      url: "https://github.com/test/open-alex-arxiv-list-rake",
      readme: 11.times.map { |index| "arXiv:2501.#{format('%05d', index)}" }.join("\n"),
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    topics = 4_000.times.map { |index| topic_data(index) }
    primary = topics.first

    stub_request(:get, "https://api.openalex.org/topics")
      .with(query: { "api_key" => "test-key", "cursor" => "*", "per_page" => "100" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "meta" => { "next_cursor" => nil }, "results" => topics }.to_json
      )
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.21105/joss.00001"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "results" => [{
            "id" => "https://openalex.org/W1",
            "doi" => "https://doi.org/10.21105/joss.00001",
            "primary_topic" => primary.slice("id").merge("score" => 0.96),
            "topics" => [primary.slice("id").merge("score" => 0.96)],
          }],
        }.to_json
      )
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.1000/linked.1"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "results" => [{
            "id" => "https://openalex.org/W2",
            "doi" => "https://doi.org/10.1000/linked.1",
            "primary_topic" => primary.slice("id").merge("score" => 0.87),
            "topics" => [primary.slice("id").merge("score" => 0.87)],
          }],
        }.to_json
      )
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.1000/metadata.1"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "results" => [{
            "id" => "https://openalex.org/W3",
            "doi" => "https://doi.org/10.1000/metadata.1",
            "primary_topic" => primary.slice("id").merge("score" => 0.82),
            "topics" => [primary.slice("id").merge("score" => 0.82)],
          }],
        }.to_json
      )
    stub_request(:get, "https://api.openalex.org/works")
      .with(query: hash_including(
        "api_key" => "test-key",
        "filter" => "doi:10.48550/arxiv.2202.01037"
      ))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "results" => [{
            "id" => "https://openalex.org/W-arxiv",
            "doi" => "https://doi.org/10.48550/arxiv.2202.01037",
            "primary_topic" => primary.slice("id").merge("score" => 0.91),
            "topics" => [primary.slice("id").merge("score" => 0.91)],
          }],
        }.to_json
      )

    output, = capture_io { Rake::Task["open_alex:sync"].execute }

    assert_equal 4_000, OpenAlexTopic.active.count
    joss_assignment = joss_project.project_open_alex_topics.reload.sole
    assert_equal primary.fetch("id"), joss_assignment.open_alex_topic.openalex_id
    assert_equal 0.96, joss_assignment.score
    linked_assignment = linked_project.project_open_alex_topics.reload.sole
    assert_equal primary.fetch("id"), linked_assignment.open_alex_topic.openalex_id
    assert_equal 0.87, linked_assignment.score
    assert_equal "readme_doi", linked_assignment.source
    assert_includes linked_project.dois, "10.13039/501100011033"
    metadata_assignments = metadata_project.project_open_alex_topics.reload
    assert_equal 2, metadata_assignments.length
    assert metadata_assignments.all? do |assignment|
      assignment.open_alex_topic.openalex_id == primary.fetch("id") &&
        assignment.score == 0.82
    end
    assert_equal [
      "citation_bib.doi",
      "codemeta.referencePublication",
    ], metadata_assignments.pluck(:source).sort
    arxiv_assignment = arxiv_project.project_open_alex_topics.reload.sole
    assert_equal primary.fetch("id"), arxiv_assignment.open_alex_topic.openalex_id
    assert_equal "readme_arxiv", arxiv_assignment.source
    assert_equal "2202.01037", arxiv_assignment.source_identifier
    assert_empty arxiv_list_project.project_open_alex_topics.reload
    assert_includes output, "OpenAlex taxonomy:"
    assert_includes output, "OpenAlex JOSS topics:"
    assert_includes output, "OpenAlex README DOI topics:"
    assert_includes output, "funding_identifiers: 1"
    assert_includes output, "OpenAlex README arXiv topics:"
    assert_includes output, "OpenAlex metadata DOI topics:"
  end

  def topic_data(index)
    {
      "id" => "https://openalex.org/T#{index}",
      "display_name" => "Topic #{index}",
      "description" => "A research topic",
      "keywords" => ["research"],
      "subfield" => { "id" => 1712, "display_name" => "Software" },
      "field" => { "id" => 17, "display_name" => "Computer Science" },
      "domain" => { "id" => 3, "display_name" => "Physical Sciences" },
      "updated_date" => "2026-08-01",
    }
  end
end
