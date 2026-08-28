require "test_helper"

class OpenAlexProjectTopicImporterTest < ActiveSupport::TestCase
  test "replaces JOSS DOI assignments with current raw OpenAlex scores" do
    project = Project.create!(
      url: "https://github.com/test/joss-project",
      joss_metadata: { "doi" => "https://doi.org/10.21105/JOSS.00001" }
    )
    old_topic = create_topic("https://openalex.org/T-old")
    current_topic = create_topic("https://openalex.org/T1")
    ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: old_topic,
      score: 0.5,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00001",
      openalex_work_id: "https://openalex.org/W-old"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W1",
        "doi" => "https://doi.org/10.21105/joss.00001",
        "primary_topic" => { "id" => current_topic.openalex_id, "score" => 0.94 },
        "topics" => [
          { "id" => current_topic.openalex_id, "score" => 0.94 },
          { "id" => "https://openalex.org/T-missing", "score" => 0.21 },
        ],
      },
    ])

    result = sync(project, client, source: "joss_doi")

    assert_equal 1, result[:matched]
    assert_equal 0, result[:without_topics]
    assert_equal 1, result[:assignments]
    assert_equal 1, result[:unmatched_topics]
    assert_not ProjectOpenAlexTopic.exists?(open_alex_topic: old_topic)

    assignment = project.project_open_alex_topics.reload.sole
    assert_equal current_topic, assignment.open_alex_topic
    assert_equal 0.94, assignment.score
    assert assignment.primary_topic?
    assert_equal "10.21105/joss.00001", assignment.source_identifier
    assert_equal "https://openalex.org/W1", assignment.openalex_work_id
  end

  test "imports every topic for scholarly DOI links in a README" do
    project = Project.create!(
      url: "https://github.com/test/linked-paper",
      readme: "Results are described at https://DOI.ORG/10.1000/PAPER.1"
    )
    primary = create_topic("https://openalex.org/T2", name: "Ecology")
    additional = create_topic("https://openalex.org/T3", name: "Biodiversity")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).with(["10.1000/paper.1"]).returns([
      {
        "id" => "https://openalex.org/W2",
        "doi" => "https://doi.org/10.1000/paper.1",
        "primary_topic" => { "id" => primary.openalex_id, "score" => 0.91 },
        "topics" => [
          { "id" => primary.openalex_id, "score" => 0.91 },
          { "id" => additional.openalex_id, "score" => 0.63 },
        ],
      },
    ])

    result = sync(project, client, source: "readme_doi")

    assert_equal 1, result[:dois]
    assert_equal 1, result[:matched]
    assert_equal 2, result[:assignments]
    assignments = project.project_open_alex_topics.reload.by_score
    assert_equal [primary, additional], assignments.map(&:open_alex_topic)
    assert assignments.first.primary_topic?
    assert assignments.none? { |assignment| assignment.source != "readme_doi" }
    assert assignments.none? { |assignment| assignment.source_identifier != "10.1000/paper.1" }
  end

  test "keeps funding DOIs in project data but excludes them from work topics" do
    project = Project.create!(
      url: "https://github.com/test/funded-paper",
      readme: <<~README
        Paper: https://doi.org/10.1000/funded-paper
        Funder: https://doi.org/10.13039/501100011033
      README
    )
    stale_assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T-funder"),
      score: 0.99,
      primary_topic: true,
      source: "readme_doi",
      source_identifier: "10.13039/501100011033",
      openalex_work_id: "https://openalex.org/W-funder"
    )
    current_topic = create_topic("https://openalex.org/T-funded-paper")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.expects(:works_by_dois).with(["10.1000/funded-paper"]).returns([{
      "id" => "https://openalex.org/W-funded-paper",
      "doi" => "https://doi.org/10.1000/funded-paper",
      "primary_topic" => { "id" => current_topic.openalex_id, "score" => 0.91 },
      "topics" => [{ "id" => current_topic.openalex_id, "score" => 0.91 }],
    }])

    result = sync(project, client, source: "readme_doi")

    assert_includes project.dois, "10.13039/501100011033"
    assert_equal 1, result[:dois]
    assert_equal 1, result[:funding_identifiers]
    assert_equal 1, result[:funding_assignments_removed]
    assert_not ProjectOpenAlexTopic.exists?(stale_assignment.id)
    assert_equal "10.1000/funded-paper",
      project.project_open_alex_topics.reload.sole.source_identifier
  end

  test "imports topics for arXiv references through their canonical DOI" do
    project = Project.create!(
      url: "https://github.com/test/arxiv-paper",
      readme: "Paper: https://arxiv.org/abs/2202.01037v2?utm_source=readme"
    )
    topic = create_topic("https://openalex.org/T-arxiv")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).with(["10.48550/arxiv.2202.01037"]).returns([{
      "id" => "https://openalex.org/W-arxiv",
      "doi" => "https://doi.org/10.48550/arxiv.2202.01037",
      "primary_topic" => { "id" => topic.openalex_id, "score" => 0.93 },
      "topics" => [{ "id" => topic.openalex_id, "score" => 0.93 }],
    }])

    result = sync(project, client, source: "readme_arxiv")

    assert_equal 1, result[:dois]
    assert_equal 1, result[:matched]
    assignment = project.project_open_alex_topics.reload.sole
    assert_equal "readme_arxiv", assignment.source
    assert_equal "2202.01037", assignment.source_identifier
    assert_equal "https://openalex.org/W-arxiv", assignment.openalex_work_id
  end

  test "skips README sources and clears their assignments when references exceed the limit" do
    arxiv_references = 11.times.map do |index|
      "arXiv:2501.#{format('%05d', index)}"
    end
    project = Project.create!(
      url: "https://github.com/test/arxiv-list",
      readme: (["DOI: 10.1000/project-paper"] + arxiv_references).join("\n")
    )
    doi_assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T-list-doi"),
      score: 0.8,
      source: "readme_doi",
      source_identifier: "10.1000/project-paper",
      openalex_work_id: "https://openalex.org/W-list-doi"
    )
    arxiv_assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T-list-arxiv"),
      score: 0.8,
      source: "readme_arxiv",
      source_identifier: "2501.00000",
      openalex_work_id: "https://openalex.org/W-list-arxiv"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.expects(:works_by_dois).never

    doi_result = sync(project, client, source: "readme_doi")
    arxiv_result = sync(project, client, source: "readme_arxiv")

    assert_equal 1, doi_result[:skipped_many_identifiers]
    assert_equal 1, arxiv_result[:skipped_many_identifiers]
    assert_not ProjectOpenAlexTopic.exists?(doi_assignment.id)
    assert_not ProjectOpenAlexTopic.exists?(arxiv_assignment.id)
  end

  test "keeps prior assignments when OpenAlex has no matching work" do
    project = Project.create!(
      url: "https://github.com/test/missing-joss-work",
      joss_metadata: { "doi" => "10.21105/joss.00002" }
    )
    assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T4"),
      score: 0.7,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00002",
      openalex_work_id: "https://openalex.org/W4"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([])

    result = sync(project, client, source: "joss_doi")

    assert_equal 1, result[:missing]
    assert ProjectOpenAlexTopic.exists?(assignment.id)
  end

  test "counts matched works without topics and clears their old assignments" do
    project = Project.create!(
      url: "https://github.com/test/joss-work-without-topics",
      joss_metadata: { "doi" => "10.21105/joss.00004" }
    )
    assignment = ProjectOpenAlexTopic.create!(
      project: project,
      open_alex_topic: create_topic("https://openalex.org/T5"),
      score: 0.7,
      source: "joss_doi",
      source_identifier: "10.21105/joss.00004",
      openalex_work_id: "https://openalex.org/W-old"
    )
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W5",
        "doi" => "https://doi.org/10.21105/joss.00004",
        "primary_topic" => nil,
        "topics" => [],
      },
    ])

    result = sync(project, client, source: "joss_doi")

    assert_equal 1, result[:matched]
    assert_equal 1, result[:without_topics]
    assert_equal 0, result[:assignments]
    assert_not ProjectOpenAlexTopic.exists?(assignment.id)
  end

  test "assigns one OpenAlex work to every project sharing its JOSS DOI" do
    projects = 2.times.map do |index|
      Project.create!(
        url: "https://github.com/test/shared-joss-doi-#{index}",
        joss_metadata: { "doi" => "10.21105/joss.00003" }
      )
    end
    topic = create_topic("https://openalex.org/T6")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).returns([
      {
        "id" => "https://openalex.org/W6",
        "doi" => "https://doi.org/10.21105/joss.00003",
        "primary_topic" => { "id" => topic.openalex_id, "score" => 0.88 },
        "topics" => [{ "id" => topic.openalex_id, "score" => 0.88 }],
      },
    ])

    result = OpenAlexProjectTopicImporter.sync!(
      source: "joss_doi",
      client: client,
      scope: Project.where(id: projects.map(&:id))
    )

    assert_equal 2, result[:processed]
    assert_equal 2, result[:matched]
    assert_equal 2, result[:assignments]
    assert_equal projects.map(&:id).sort,
      ProjectOpenAlexTopic.where(open_alex_topic: topic).pluck(:project_id).sort
  end

  test "imports metadata DOI topics with field and relation provenance" do
    project = Project.create!(
      url: "https://github.com/test/metadata-dois",
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite the paper below.
        title: Example software
        authors:
          - family-names: Doe
            given-names: Jane
        preferred-citation:
          type: article
          title: Example paper
          authors:
            - family-names: Doe
              given-names: Jane
          doi: 10.1000/shared-paper
      CFF
      codemeta: {
        "referencePublication" => "https://doi.org/10.1000/shared-paper",
      }.to_json,
      zenodo: {
        "related_identifiers" => [{
          "scheme" => "doi",
          "identifier" => "10.1000/shared-paper",
          "relation" => "isDocumentedBy",
        }],
      }.to_json
    )
    topic = create_topic("https://openalex.org/T-metadata")
    client = OpenAlexApiClient.new(api_key: "test-key")
    client.stubs(:works_by_dois).with(["10.1000/shared-paper"]).returns([{
      "id" => "https://openalex.org/W-metadata",
      "doi" => "https://doi.org/10.1000/shared-paper",
      "primary_topic" => { "id" => topic.openalex_id, "score" => 0.9 },
      "topics" => [{ "id" => topic.openalex_id, "score" => 0.9 }],
    }])

    result = sync(project, client, source: "metadata_doi")

    assert_equal 1, result[:dois]
    assert_equal 1, result[:matched]
    assert_equal 3, result[:assignments]
    assignments = project.project_open_alex_topics.reload
    assert_equal [
      "citation_cff.preferred-citation.doi",
      "codemeta.referencePublication",
      "zenodo.related_identifiers.isDocumentedBy",
    ], assignments.pluck(:source).sort
    assert_equal ["10.1000/shared-paper"], assignments.pluck(:source_identifier).uniq
  end

  test "rejects unknown label sources" do
    error = assert_raises(ArgumentError) do
      OpenAlexProjectTopicImporter.sync!(source: "unknown", client: stub)
    end

    assert_equal "Unknown OpenAlex topic source: unknown", error.message
  end

  def sync(project, client, source:)
    OpenAlexProjectTopicImporter.sync!(
      source: source,
      client: client,
      scope: Project.where(id: project.id)
    )
  end

  def create_topic(openalex_id, name: "Research Software")
    OpenAlexTopic.create!(
      openalex_id: openalex_id,
      display_name: name,
      subfield_id: "1712",
      subfield_name: "Software",
      field_id: "17",
      field_name: "Computer Science",
      domain_id: "3",
      domain_name: "Physical Sciences"
    )
  end
end
