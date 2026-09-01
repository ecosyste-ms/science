require "test_helper"

class JossPublicationIndexerTest < ActiveSupport::TestCase
  test "indexes a JOSS paper with ordered authors and an editor" do
    project = create_project(joss_metadata)

    result = JossPublicationIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 1, result.fetch(:papers)
    assert_equal 2, result.fetch(:authors)
    assert_equal 1, result.fetch(:editors)

    paper = Paper.find_by!(doi: "10.21105/joss.12345")
    assert_equal "Example Research Software", paper.title
    assert_equal Date.new(2026, 8, 30), paper.publication_date.to_date
    assert_includes paper.urls, "https://doi.org/10.21105/joss.12345"
    assert_includes paper.urls, "https://joss.theoj.org/papers/10.21105/joss.12345.pdf"

    source = project.mention_sources.find_by!(source: "joss")
    assert_equal paper, source.mention.paper
    assert_equal "10.21105/joss.12345", source.source_identifier
    assert_equal "Example Research Software", source.raw_data.fetch("title")

    authors = paper.paper_authors.order(:role, :position)
    first = authors.find_by!(role: "author", position: 1)
    second = authors.find_by!(role: "author", position: 2)
    editor = authors.find_by!(role: "editor")
    assert_equal "Ada Augusta Lovelace", first.display_name
    assert_equal "Ada Augusta", first.given_names
    assert_equal "Lovelace", first.family_names
    assert_equal "0000-0002-1825-0097", first.orcid
    assert_equal "Example University", first.affiliation
    assert_equal "Grace Hopper", second.display_name
    assert_equal "Editor Person", editor.display_name
    assert_equal "0000-0001-5109-3700", editor.orcid

    project.reload
    assert project.joss_publication_indexed_at.present?
    assert_nil project.joss_publication_index_error
    assert_equal JossPublicationIndexer::CURRENT_VERSION,
      project.joss_publication_index_version
    assert_nil project.author_identities_indexed_at
  end

  test "replaces changed JOSS author positions and removes stale authors" do
    project = create_project(joss_metadata)
    JossPublicationIndexer.new(project).sync!
    paper = project.papers.first
    first_id = paper.paper_authors.find_by!(role: "author", position: 1).id
    project.update_columns(
      author_identities_indexed_at: 1.day.ago,
      author_identities_index_error: "old error"
    )
    changed = joss_metadata.merge(
      "authors" => [
        {
          "given_name" => "Katherine",
          "last_name" => "Johnson",
          "orcid" => "0000-0003-1419-2405",
        },
      ],
      "editor_name" => nil,
      "editor_orcid" => nil
    )

    project.update!(joss_metadata: changed)
    result = JossPublicationIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 1, paper.paper_authors.reload.count
    author = paper.paper_authors.first
    assert_equal first_id, author.id
    assert_equal "Katherine Johnson", author.display_name
    assert_nil author.author_id
    assert_nil project.reload.author_identities_indexed_at
    assert_nil project.author_identities_index_error
  end

  test "skips an unchanged indexed snapshot" do
    project = create_project(joss_metadata)
    JossPublicationIndexer.new(project).sync!
    indexed_at = project.reload.joss_publication_indexed_at
    author_updated_at = PaperAuthor.first.updated_at

    travel 1.minute do
      result = JossPublicationIndexer.new(project).sync!

      assert_not result.fetch(:indexed)
      assert_equal indexed_at, project.reload.joss_publication_indexed_at
      assert_equal author_updated_at, PaperAuthor.first.updated_at
    end
  end

  test "records a missing DOI as an error" do
    project = create_project(joss_metadata.except("doi"))

    result = JossPublicationIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:failed)
    assert_match "DOI is missing or invalid",
      project.reload.joss_publication_index_error
    assert_empty project.papers
    assert_equal 0,
      JossPublicationIndexer.sync_batch!(limit: 1).fetch(:selected)
  end

  test "removes JOSS evidence and authors when metadata is removed" do
    project = create_project(joss_metadata)
    JossPublicationIndexer.new(project).sync!
    paper = project.papers.first

    project.update!(joss_metadata: nil)
    result = JossPublicationIndexer.sync_batch!(limit: 1)

    assert result.fetch(:indexed)
    assert_empty project.mention_sources.reload
    assert_empty project.mentions.reload
    assert_empty paper.paper_authors.reload
    assert project.reload.joss_publication_indexed_at.present?
  end

  test "reuses an existing paper with a differently cased DOI" do
    existing = Paper.create!(doi: "10.21105/JOSS.12345", title: "Old title")
    project = create_project(joss_metadata)

    JossPublicationIndexer.new(project).sync!

    assert_equal 1, Paper.count
    assert_equal existing, project.papers.first
    assert_equal "Example Research Software", existing.reload.title
  end

  test "processes a bounded batch of visible projects" do
    first = create_project(joss_metadata.merge("doi" => "10.21105/joss.10001"))
    second = create_project(joss_metadata.merge("doi" => "10.21105/joss.10002"))

    result = JossPublicationIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_equal 1,
      Project.where(id: [first.id, second.id])
        .where.not(joss_publication_indexed_at: nil)
        .count
  end

  test "rejects an invalid batch limit" do
    error = assert_raises(ArgumentError) do
      JossPublicationIndexer.sync_batch!(limit: 0)
    end

    assert_equal "limit must be between 1 and 1000", error.message
  end

  def create_project(metadata)
    @project_number = @project_number.to_i + 1
    Project.create!(
      url: "https://github.com/test/joss-publication-#{@project_number}",
      science_score: 20,
      joss_metadata: metadata
    )
  end

  def joss_metadata
    {
      "doi" => "https://doi.org/10.21105/JOSS.12345",
      "title" => "Example Research Software",
      "published_at" => "2026-08-30",
      "pdf_url" => "https://joss.theoj.org/papers/10.21105/joss.12345.pdf",
      "authors" => [
        {
          "given_name" => "Ada",
          "middle_name" => "Augusta",
          "last_name" => "Lovelace",
          "orcid" => "https://orcid.org/0000-0002-1825-0097",
          "affiliation" => "Example University",
        },
        {
          "given_name" => "Grace",
          "last_name" => "Hopper",
        },
      ],
      "editor_name" => "Editor Person",
      "editor_orcid" => "0000-0001-5109-3700",
    }
  end
end
