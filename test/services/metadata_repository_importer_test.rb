require "test_helper"

class MetadataRepositoryImporterTest < ActiveSupport::TestCase
  GITLAB_HOSTS = ["gitlab.com", "gitlab.example.org"].freeze

  setup do
    SyncProjectWorker.jobs.clear
  end

  teardown do
    SyncProjectWorker.jobs.clear
  end

  test "normalizes direct GitHub and configured GitLab repository URLs" do
    assert_equal "https://github.com/science-example/project",
      normalize("https://GitHub.com/science-example/Project/tree/main")
    assert_equal "https://github.com/science-example/project",
      normalize("https://github.com/science-example/project.git).")
    assert_equal "https://gitlab.example.org/group/subgroup/project",
      normalize("https://gitlab.example.org/group/subgroup/project/-/blob/main/README.md")
  end

  test "rejects ambiguous, unsupported, malformed, and placeholder URLs" do
    assert_nil normalize("https://example.github.io/project")
    assert_nil normalize("https://github.com/apps/example")
    assert_nil normalize("https://github.com/owner/repo")
    assert_nil normalize("https://github.com/username/real-project")
    assert_nil normalize("https://github.com/real-owner/reponame")
    assert_nil normalize("https://github.com/real-owner/your-repo-for-project")
    assert_nil normalize("https://github.com/owner.github.io/project")
    assert_nil normalize("https://github.com/https://github.com/example/project")
    assert_nil normalize("https://bitbucket.org/example/project")
    assert_nil normalize("https://unconfigured.example.org/example/project")
    assert_nil normalize("https://gitlab.com/explore/projects/topics/science")
  end

  test "uses local GitLab hosts when the repos host catalog is unavailable" do
    Host.create!(
      name: "gitlab.local.example",
      url: "https://gitlab.local.example",
      kind: "gitlab"
    )
    client = mock
    client.expects(:gitlab_hosts).raises(
      ReposApiClient::RequestError,
      "unavailable"
    )

    configured_hosts = nil
    _, error_output = capture_io do
      configured_hosts = MetadataRepositoryImporter.configured_gitlab_hosts(
        client: client
      )
    end

    assert_includes configured_hosts, "gitlab.com"
    assert_includes configured_hosts, "gitlab.local.example"
    assert_includes error_output, "unavailable"
  end

  test "imports missing repositories once and enqueues their production sync path" do
    existing = Project.create!(url: "https://github.com/research-org/existing")
    source = Project.create!(
      url: "https://github.com/research-org/source",
      science_score: 20,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software.
        title: Source
        authors:
          - family-names: Doe
            given-names: Jane
        repository-code: https://github.com/research-org/source
        references:
          - type: software
            title: Existing
            authors:
              - family-names: Doe
                given-names: Jane
            repository-code: https://github.com/research-org/existing
      CFF
      codemeta: {
        "codeRepository" => [
          "https://github.com/research-org/existing/tree/main",
          "https://gitlab.example.org/group/new-project/-/blob/main/README.md",
          "https://example.github.io/project",
          "https://github.com/apps/example",
        ],
      }.to_json,
      zenodo: {
        "related_identifiers" => [{
          "identifier" => "https://bitbucket.org/example/old-project",
          "relation" => "isDerivedFrom",
          "scheme" => "url",
        }],
      }.to_json
    )
    bib_source = Project.create!(
      url: "https://github.com/research-org/bib-source",
      science_score: 20,
      citation_file: <<~BIBTEX
        @software{new,
          url = {https://github.com/research-org/bib-project/issues},
          note = {https://doi.org/10.1000/example}
        }
      BIBTEX
    )

    result = MetadataRepositoryImporter.sync!(
      scope: Project.where(id: [source.id, bib_source.id]),
      gitlab_hosts: GITLAB_HOSTS
    )

    assert_equal 2, result[:projects]
    assert_equal 2, result[:processed]
    assert_equal 9, result[:links]
    assert_equal 4, result[:repositories]
    assert_equal 3, result[:github]
    assert_equal 1, result[:gitlab]
    assert_equal 1, result[:self]
    assert_equal 1, result[:existing]
    assert_equal 2, result[:new]
    assert_equal 2, result[:created]
    assert_equal 1, result[:bitbucket]
    assert_equal 3, result[:skipped]
    assert_equal 0, result[:failed]
    assert Project.exists?(url: "https://gitlab.example.org/group/new-project")
    assert Project.exists?(url: "https://github.com/research-org/bib-project")
    assert Project.exists?(existing.id)
    assert_equal 2, SyncProjectWorker.jobs.length
  end

  test "dry run reports new repositories without writing or enqueueing" do
    source = Project.create!(
      url: "https://github.com/research-org/dry-run-source",
      science_score: 20,
      codemeta: {
        "codeRepository" => "https://github.com/research-org/dry-run-target",
      }.to_json
    )

    result = MetadataRepositoryImporter.sync!(
      scope: Project.where(id: source.id),
      gitlab_hosts: GITLAB_HOSTS,
      dry_run: true
    )

    assert_equal 1, result[:new]
    assert_equal 0, result[:created]
    assert_not Project.exists?(url: "https://github.com/research-org/dry-run-target")
    assert_empty SyncProjectWorker.jobs
  end

  def normalize(url)
    MetadataRepositoryImporter.normalize_repository_url(
      url,
      gitlab_hosts: GITLAB_HOSTS
    )
  end
end
