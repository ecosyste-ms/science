require "test_helper"
require "rake"

class ProjectsRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[
    LIMIT COHORT SHARD_COUNT SHARD DRY_RUN RETRY_ERRORS
  ].freeze

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

  test "sync_citation_authors indexes CodeMeta and Zenodo authors and updates changed sources" do
    project = Project.create!(
      url: "https://github.com/test/metadata-people", science_score: 50,
      codemeta: {
        "author" => [
          { "@type" => "Person", "givenName" => "Ada", "familyName" => "Lovelace", "@id" => "https://orcid.org/0000-0002-1825-0097", "affiliation" => { "name" => "Example University" } },
          { "@type" => "Organization", "name" => "Research Group" }
        ]
      }.to_json,
      zenodo: { "creators" => [{ "name" => "Hopper, Grace", "affiliation" => "Research Institute" }] }.to_json
    )

    capture_io { Rake::Task["projects:sync_citation_authors"].execute }

    assert_equal 3, project.project_authors.count
    ada = project.project_authors.find_by!(source: "codemeta", position: 1)
    assert_equal "Ada Lovelace", ada.display_name
    assert_equal "0000-0002-1825-0097", ada.orcid
    assert_equal "Example University", ada.affiliation
    assert_equal "author[0]", ada.source_path
    assert_equal "organization", project.project_authors.find_by!(source: "codemeta", position: 2).author_kind
    grace = project.project_authors.find_by!(source: "zenodo")
    assert_equal "Grace", grace.given_names
    assert_equal "Hopper", grace.family_names
    assert_equal "Research Institute", grace.affiliation

    project.reload.update!(codemeta: nil, zenodo: { "creators" => [{ "name" => "New Author" }] }.to_json)
    assert_nil project.citation_authors_indexed_at
    capture_io { Rake::Task["projects:sync_citation_authors"].execute }

    assert_equal ["New Author"], project.project_authors.reload.pluck(:display_name)
    project.reload.update!(zenodo: "{")
    capture_io { Rake::Task["projects:sync_citation_authors"].execute }
    assert project.reload.citation_authors_index_error.present?
    assert_equal ["New Author"], project.project_authors.reload.pluck(:display_name)
  end

  test "metadata contributors retain their role in author pages and counts" do
    project = Project.create!(url: "https://github.com/test/metadata-contributor", science_score: 50,
      codemeta: { "maintainer" => { "name" => "Ada Lovelace", "@id" => "https://orcid.org/0000-0002-1825-0097" } }.to_json)

    capture_io { Rake::Task["projects:sync_citation_authors"].execute }
    AuthorIdentityIndexer.new(project.reload).sync!

    credit = project.project_authors.find_by!(authorship_kind: "maintainer")
    assert_equal "maintainer[0]", credit.source_path
    author = credit.author
    assert author.present?
    assert_empty author.software_projects
    assert_equal [project.id], author.contributed_projects.pluck(:id)
    counts = Author.role_counts([author.id]).fetch(author.id)
    assert_equal 1, counts[:contributed_projects]
    assert_equal 0, counts[:preferred_citation_projects]
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

  test "import_joss rescores an existing project when JOSS metadata changes" do
    project = Project.create!(
      url: "https://github.com/test/joss-import",
      science_score: 0,
      science_score_breakdown: {
        "score" => 0,
        "breakdown" => {
          "has_joss_paper" => { "present" => false },
        },
      }
    )
    paper = {
      software_repository: "https://github.com/Test/Joss-Import",
      title: "Imported JOSS Paper",
      year: 2026,
      doi: "10.21105/joss.12345",
    }
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=1")
      .to_return(status: 200, body: [paper].to_json)
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Rake::Task["projects:import_joss"].execute }

    project.reload
    assert_operator project.science_score, :>=, 85
    assert project.science_score_breakdown.dig(:breakdown, :has_joss_paper, :present)
  end

  test "import_joss reuses a project found through a repository alias" do
    project = Project.create!(
      url: "https://github.com/research/current-name",
      science_score: 20
    )
    ProjectRepositoryAlias.create!(
      project: project,
      url: "https://github.com/research/old-name"
    )
    paper = {
      software_repository: "https://github.com/Research/Old-Name.git/",
      title: "Renamed Research Software",
      year: 2026,
      doi: "10.21105/joss.12346",
    }
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=1")
      .to_return(status: 200, body: [paper].to_json)
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=2")
      .to_return(status: 200, body: [].to_json)

    assert_no_difference "Project.count" do
      capture_io { Rake::Task["projects:import_joss"].execute }
    end

    assert_equal "Renamed Research Software",
      project.reload.joss_metadata.fetch("title")
  end

  test "import_joss keeps an existing JOSS source when a duplicate URL exists" do
    project = Project.create!(
      url: "https://github.com/research/current-name",
      science_score: 20,
      joss_metadata: { "doi" => "10.21105/joss.12347", "title" => "Old title" }
    )
    ProjectRepositoryAlias.create!(
      project: project,
      url: "https://github.com/research/old-name"
    )
    duplicate = Project.create!(
      url: "https://github.com/research/old-name",
      science_score: 20
    )
    paper_record = Paper.create!(doi: "10.21105/joss.12347")
    mention = Mention.create!(
      project: project,
      paper: paper_record,
      created_by_source: "joss"
    )
    MentionSource.create!(
      mention: mention,
      source: "joss",
      source_identifier: "10.21105/joss.12347",
      source_digest: "old",
      raw_data: {}
    )
    paper = {
      software_repository: "https://github.com/research/old-name",
      title: "Current title",
      year: 2026,
      doi: "10.21105/joss.12347",
    }
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=1")
      .to_return(status: 200, body: [paper].to_json)
    stub_request(:get, "https://joss.theoj.org/papers/published.json?page=2")
      .to_return(status: 200, body: [].to_json)

    capture_io { Rake::Task["projects:import_joss"].execute }

    assert_equal "Current title", project.reload.joss_metadata.fetch("title")
    assert_nil duplicate.reload.joss_metadata
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
      repository: {
        "metadata" => { "files" => { "citation" => "CITATION.CFF" } },
      },
      citation_file: <<~CFF
        # Generated citation metadata
        ---
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

  test "rescore_citations persists classified citation weights in batches" do
    cff = Project.create!(
      url: "https://github.com/test/rescore-cff",
      science_score: 0,
      science_score_breakdown: old_citation_breakdown,
      citation_file: valid_cff
    )
    bibtex = Project.create!(
      url: "https://github.com/test/rescore-bibtex",
      science_score: 0,
      science_score_breakdown: old_citation_breakdown,
      citation_file: "@software{example, title = {Example Software}}"
    )
    unstructured = Project.create!(
      url: "https://github.com/test/rescore-unstructured",
      science_score: 16,
      science_score_breakdown: old_citation_breakdown,
      citation_file: "Please cite the project README."
    )
    ENV["LIMIT"] = "2"

    first_output, = capture_io do
      Rake::Task["projects:rescore_citations"].execute
    end

    assert_equal 16.0, cff.reload.science_score
    assert_equal "cff", citation_format(cff)
    assert_equal 8.0, bibtex.reload.science_score
    assert_equal "bibtex", citation_format(bibtex)
    assert_equal 16, unstructured.reload.science_score
    assert_includes first_output, "selected: 2"
    assert_includes first_output, "updated: 2"

    ENV["AFTER_ID"] = bibtex.id.to_s
    second_output, = capture_io do
      Rake::Task["projects:rescore_citations"].execute
    end

    assert_equal 0.0, unstructured.reload.science_score
    assert_equal "unstructured", citation_format(unstructured)
    assert_includes second_output, "selected: 1"
    assert_includes second_output, "updated: 1"
  end

  test "rescore_overlapping_science_signals updates only the bounded target scope" do
    zenodo = Project.create!(
      url: "https://github.com/test/archived-result",
      repository: { "full_name" => "test/archived-result" },
      readme: <<~README,
        Archive: https://doi.org/10.5281/zenodo.1234
        Record: https://zenodo.org/records/1234
      README
      science_score: 21,
      science_score_breakdown: old_overlapping_signal_breakdown
    )
    homework = Project.create!(
      url: "https://github.com/test/ase-homework-group22",
      repository: { "full_name" => "test/ase-homework-group22" },
      readme: <<~README,
        Paper: https://doi.org/10.1234/example
        Preprint: https://arxiv.org/abs/1234.5678
      README
      science_score: 21,
      science_score_breakdown: old_science_score_breakdown
    )
    legitimate = Project.create!(
      url: "https://github.com/test/traffic_assignment",
      repository: { "full_name" => "test/traffic_assignment" },
      readme: homework.readme,
      science_score: 21,
      science_score_breakdown: old_science_score_breakdown
    )
    ENV["LIMIT"] = "10"

    output, = capture_io do
      Rake::Task["projects:rescore_overlapping_science_signals"].execute
    end

    assert_equal 13.0, zenodo.reload.science_score
    assert_equal "has_doi_in_readme", zenodo.science_score_breakdown.dig(
      :breakdown,
      :has_academic_links,
      :duplicate_of
    )
    assert_equal 4.2, homework.reload.science_score
    assert_includes homework.science_score_breakdown.dig(
      :breakdown,
      :negative_indicators,
      :details
    ), "name:homework"
    assert_equal 21, legitimate.reload.science_score
    assert_equal old_science_score_breakdown.with_indifferent_access,
      legitimate.science_score_breakdown
    assert_includes output, "selected: 2"
    assert_includes output, "updated: 2"
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
    assert_equal 2, author.reload.public_evidence_count
    assert_includes output, "selected: 1"
    assert_includes output, "linked_contributors: 1"
    assert_includes output, "account_author_links: 1"
  end

  test "sync_author_identities limits contributor updates through the rake entrypoint" do
    host = Host.create!(name: "Bounded Rake Identity GitHub")
    project = Project.create!(
      url: "https://github.com/test/bounded-author-identity-rake",
      science_score: 20,
      host: host,
      commits: {
        "committers" => 120.times.map do |index|
          {
            "name" => "Contributor #{index}",
            "login" => "bounded-contributor-#{index}",
            "count" => 1,
          }
        end,
      }
    )
    ProjectContributorIndexer.new(project).sync!
    ENV["LIMIT"] = "1"
    statements = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      sql = payload.fetch(:sql)
      statements << sql if sql.start_with?('UPDATE "project_contributors"')
    end

    output, = capture_io do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        Rake::Task["projects:sync_author_identities"].execute
      end
    end

    clear_statements = statements.reject { |sql| sql.include?(" AS record ") }
    assignment_statements = statements.select { |sql| sql.include?(" AS record ") }
    assert_equal 2, clear_statements.length
    assert_equal 6, assignment_statements.length
    assert clear_statements.all? do |sql|
      sql.match(/ IN \(([^)]+)\)/).captures.sole.split(",").length <= 96
    end
    assert assignment_statements.all? do |sql|
      sql.scan("), (").length + 1 <= 20
    end
    assert_equal 120, project.project_contributors.reload.where.not(
      developer_account_id: nil
    ).count
    assert_includes output, "indexed: 1"
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

  def citation_format(project)
    project.science_score_breakdown.dig(
      :breakdown,
      :has_citation_file,
      :format
    )
  end

  def old_citation_breakdown
    {
      "score" => 16,
      "breakdown" => {
        "has_citation_file" => {
          "present" => true,
          "description" => "CITATION.cff file",
        },
      },
    }
  end

  def old_overlapping_signal_breakdown
    old_science_score_breakdown.deep_merge(
      "breakdown" => {
        "has_doi_in_readme" => {
          "present" => true,
          "archive_dois" => 1,
        },
        "has_academic_links" => {
          "present" => true,
          "details" => "Links to: zenodo.org",
        },
      }
    )
  end

  def old_science_score_breakdown
    {
      "score" => 21,
      "breakdown" => {
        "negative_indicators" => {
          "present" => false,
          "penalty" => 0.0,
          "details" => nil,
        },
      },
      "max_score" => 100,
    }
  end

  def valid_cff
    <<~CFF
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: Ada
          family-names: Lovelace
    CFF
  end
end
