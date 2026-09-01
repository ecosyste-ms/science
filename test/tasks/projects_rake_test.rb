require "test_helper"
require "rake"

class ProjectsRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[LIMIT COHORT SHARD_COUNT SHARD DRY_RUN RETRY_ERRORS].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:fetch_brief")
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
    SyncProjectWorker.jobs.clear
  end

  teardown do
    ENV_KEYS.each { |key| ENV.delete(key) }
    FetchBriefWorker.jobs.clear
    SyncProjectWorker.jobs.clear
  end

  test "fetch_brief enqueues eligible projects through the application service" do
    joss = create_project("joss", joss: true)
    create_project("non-joss")
    ENV["LIMIT"] = "10"
    ENV["COHORT"] = "joss"

    output, = capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_equal [[joss.id]], FetchBriefWorker.jobs.map { |job| job["args"] }
    assert_includes output, "Enqueued 1 Brief jobs"
    assert_includes output, "cohort=joss"
  end

  test "fetch_brief defaults to a batch of 50" do
    51.times { |index| create_project("default-limit-#{index}") }

    capture_io { Rake::Task["projects:fetch_brief"].execute }

    assert_equal 50, FetchBriefWorker.jobs.size
  end

  test "fetch_brief rejects an invalid cohort" do
    ENV["COHORT"] = "unknown"

    assert_raises(SystemExit) do
      capture_io { Rake::Task["projects:fetch_brief"].execute }
    end
    assert_empty FetchBriefWorker.jobs
  end

  test "sync_dependencies indexes a bounded project batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/dependency-rake",
      dependencies: [
        {
          "ecosystem" => "rubygems",
          "filepath" => "Gemfile",
          "kind" => "manifest",
          "dependencies" => [
            {
              "package_name" => "rails",
              "ecosystem" => "rubygems",
              "requirements" => "~> 8.1",
              "direct" => true,
              "kind" => "runtime",
              "optional" => false,
            },
          ],
        },
      ]
    )
    ENV["LIMIT"] = "1"

    output, = capture_io { Rake::Task["projects:sync_dependencies"].execute }

    assert_equal ["rails"], project.project_dependencies.reload.pluck(:package_name)
    assert project.reload.dependencies_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "dependencies: 1"
  end

  test "sync_citation_authors indexes a bounded batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/citation-author-rake",
      science_score: 20,
      citation_file: <<~CFF
        cff-version: 1.2.0
        message: Cite this software
        title: Example Software
        authors:
          - given-names: Ada
            family-names: Lovelace
      CFF
    )
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_citation_authors"].execute
    end

    assert_equal ["Ada Lovelace"],
      project.project_authors.reload.pluck(:display_name)
    assert project.reload.citation_authors_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "authors: 1"
  end

  test "sync_joss_publications normalizes paper authors for identity linking" do
    project = Project.create!(
      url: "https://github.com/test/joss-publication-rake",
      science_score: 20,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software
        title: Example Software
        authors:
          - given-names: Ada
            family-names: Lovelace
            orcid: https://orcid.org/0000-0002-1825-0097
      CFF
      joss_metadata: {
        "doi" => "10.21105/joss.12345",
        "title" => "Example Paper",
        "published_at" => "2026-08-30",
        "authors" => [
          {
            "given_name" => "Ada",
            "last_name" => "Lovelace",
            "orcid" => "0000-0002-1825-0097",
          },
        ],
      }
    )
    ProjectCitationAuthorIndexer.new(project).sync!
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_joss_publications"].execute
    end
    identity_output, = capture_io do
      Rake::Task["projects:sync_author_identities"].execute
    end

    project_author = project.project_authors.first
    paper_author = project.papers.first.paper_authors.first
    assert_equal project_author.author, paper_author.author
    assert_equal "orcid:0000-0002-1825-0097",
      paper_author.author.canonical_key
    assert_equal "orcid", paper_author.author_match_kind
    assert_includes output, "selected: 1"
    assert_includes output, "authors: 1"
    assert_includes identity_output, "linked_paper_author_observations: 1"
  end

  test "sync_contributors indexes a bounded batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/contributor-rake",
      science_score: 20,
      commits: {
        "committers" => [
          {
            "name" => "Ada Lovelace",
            "email" => "ada@example.edu",
            "login" => "adal",
            "count" => 4,
          },
          {
            "name" => "copilot-swe-agent[bot]",
            "login" => "copilot",
            "count" => 2,
          },
        ],
      }
    )
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_contributors"].execute
    end

    contributor = project.project_contributors.first
    assert_equal "Ada Lovelace", contributor.name
    assert_equal 4, contributor.contributions_count
    copilot = project.project_contributors.find_by!(login: "copilot")
    assert_equal "bot", copilot.account_kind
    assert_equal "name_bot_suffix", copilot.classification_reason
    assert project.reload.contributors_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "contributors: 2"
  end

  test "sync_author_identities links realistic indexed evidence through the rake entrypoint" do
    host = Host.create!(name: "Rake Identity GitHub")
    project = Project.create!(
      url: "https://github.com/test/author-identity-rake",
      science_score: 20,
      host: host,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software
        title: Example Software
        authors:
          - given-names: Ada
            family-names: Lovelace
            email: ada@example.edu
            orcid: https://orcid.org/0000-0002-1825-0097
      CFF
      commits: {
        "committers" => [
          {
            "name" => "Ada Lovelace",
            "email" => "ada@example.edu",
            "login" => "adal",
            "count" => 4,
          },
        ],
      }
    )
    ProjectCitationAuthorIndexer.new(project).sync!
    ProjectContributorIndexer.new(project).sync!
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_author_identities"].execute
    end

    author = Author.find_by!(canonical_key: "orcid:0000-0002-1825-0097")
    contributor = project.project_contributors.first
    assert_equal author, contributor.author
    assert contributor.developer_account.present?
    assert project.reload.author_identities_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "linked_contributors: 1"
    assert_includes output, "account_author_links: 1"
  end

  test "sync_author_identities handles inferred ORCIDs and provider conflicts through the rake entrypoint" do
    host = Host.create!(name: "Rake Conflict GitHub")
    email_only = Project.create!(
      url: "https://github.com/test/email-only-rake",
      science_score: 20,
      host: host,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software
        title: Email-only Software
        authors:
          - given-names: Ada
            family-names: Lovelace
            email: shared@example.edu
      CFF
      commits: {
        "committers" => [
          {
            "name" => "First",
            "login" => "shared",
            "uuid" => "42",
            "count" => 2,
          },
          {
            "name" => "Second",
            "login" => "shared",
            "uuid" => "84",
            "count" => 3,
          },
        ],
      }
    )
    identified = Project.create!(
      url: "https://github.com/test/identified-rake",
      science_score: 20,
      citation_file: <<~CFF,
        cff-version: 1.2.0
        message: Cite this software
        title: Identified Software
        authors:
          - given-names: Ada
            family-names: Lovelace
            email: shared@example.edu
            orcid: https://orcid.org/0000-0002-1825-0097
      CFF
      commits: { "committers" => [] }
    )
    [email_only, identified].each do |project|
      ProjectCitationAuthorIndexer.new(project).sync!
      ProjectContributorIndexer.new(project).sync!
    end
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_author_identities"].execute
    end

    author = email_only.project_authors.first.author
    assert_equal "orcid:0000-0002-1825-0097", author.canonical_key
    assert_equal "0000-0002-1825-0097",
      author.identifiers.find_by!(scheme: "orcid").value
    assert_empty email_only.project_contributors.reload.where.not(
      developer_account_id: nil
    )
    assert_includes output, "ambiguous: 2"
  end

  test "sync_repository_aliases indexes a bounded batch through the rake entrypoint" do
    project = Project.create!(
      url: "https://github.com/test/current-name",
      repository: { "previous_names" => ["test/old-name"] }
    )
    ENV["LIMIT"] = "1"

    output, = capture_io do
      Rake::Task["projects:sync_repository_aliases"].execute
    end

    assert_equal ["https://github.com/test/old-name"],
      project.repository_aliases.pluck(:url)
    assert project.reload.repository_aliases_indexed_at.present?
    assert_includes output, "selected: 1"
    assert_includes output, "indexed: 1"
    assert_includes output, "aliases: 1"
  end

  test "import_metadata_repositories creates and enqueues discovered repositories" do
    source = Project.create!(
      url: "https://github.com/metadata-test/metadata-source",
      science_score: 20,
      codemeta: {
        "codeRepository" => "https://github.com/metadata-test/metadata-target",
      }.to_json
    )
    MetadataRepositoryImporter.stubs(:configured_gitlab_hosts)
      .returns(["gitlab.com"])

    output, = capture_io do
      Rake::Task["projects:import_metadata_repositories"].execute
    end

    target = Project.find_by!(url: "https://github.com/metadata-test/metadata-target")
    assert_equal [[target.id]], SyncProjectWorker.jobs.map { |job| job["args"] }
    assert_includes output, "Metadata repository import:"
    assert_includes output, "created: 1"
    assert Project.exists?(source.id)
  end

  test "import_metadata_repositories skips repository previous names" do
    Project.create!(
      url: "https://github.com/metadata-test/current-target",
      repository: {
        "previous_names" => ["metadata-test/old-target"],
      }
    )
    Project.create!(
      url: "https://github.com/metadata-test/alias-source",
      science_score: 20,
      codemeta: {
        "codeRepository" => "https://github.com/metadata-test/old-target",
      }.to_json
    )
    MetadataRepositoryImporter.stubs(:configured_gitlab_hosts)
      .returns(["gitlab.com"])

    output, = capture_io do
      Rake::Task["projects:import_metadata_repositories"].execute
    end

    assert_includes output, "existing: 1"
    assert_includes output, "aliases: 1"
    assert_not Project.exists?(url: "https://github.com/metadata-test/old-target")
    assert_empty SyncProjectWorker.jobs
  end

  def create_project(name, joss: false, brief: nil, science_score: 20, repository: true)
    Project.create!(
      url: "https://github.com/test/#{name}",
      repository: repository ? { "clone_url" => "https://github.com/test/#{name}.git" } : nil,
      science_score: science_score,
      brief: brief,
      joss_metadata: joss ? { "doi" => "10.21105/joss.test" } : nil
    )
  end
end
