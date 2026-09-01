require "test_helper"

class ProjectCitationAuthorIndexerTest < ActiveSupport::TestCase
  test "indexes software and preferred citation authors" do
    project = create_project(citation_file: full_cff)

    result = ProjectCitationAuthorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 3, result.fetch(:authors)
    assert_equal 1, result.fetch(:software_people)
    assert_equal 1, result.fetch(:software_organizations)
    assert_equal 1, result.fetch(:publication_people)
    assert_equal 0, result.fetch(:publication_organizations)

    authors = project.project_authors.order(:authorship_kind, :position)
    publication_author = authors.find_by!(authorship_kind: "preferred_citation")
    software_person = authors.find_by!(
      authorship_kind: "software",
      author_kind: "person"
    )
    organization = authors.find_by!(author_kind: "organization")

    assert_equal "Grace Hopper", publication_author.display_name
    assert_equal "preferred-citation.authors[0]", publication_author.source_path
    assert_nil publication_author.orcid
    assert_equal "Ada Lovelace", software_person.display_name
    assert_equal "ada@example.edu", software_person.email
    assert_equal "0000-0002-1825-0097", software_person.orcid
    assert_equal "Example University", software_person.affiliation
    assert_equal "Ada", software_person.raw_data.fetch("given-names")
    assert_equal "Example Research Group", organization.display_name
    assert_nil organization.orcid

    project.reload
    assert project.citation_authors_indexed_at.present?
    assert_nil project.citation_authors_index_error
    assert_equal ProjectCitationAuthorIndexer::CURRENT_VERSION,
      project.citation_authors_index_version
    assert_equal Digest::SHA256.hexdigest(full_cff),
      project.citation_authors_source_digest
  end

  test "upserts changed positions and removes stale authors" do
    project = create_project(citation_file: two_person_cff)
    ProjectCitationAuthorIndexer.new(project).sync!
    first_position_id = project.project_authors.find_by!(position: 1).id
    project.update_columns(
      author_identities_indexed_at: 1.day.ago,
      author_identities_index_error: "old error"
    )

    project.update!(citation_file: one_person_cff)
    result = ProjectCitationAuthorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal 1, project.project_authors.count
    author = project.project_authors.first
    assert_equal first_position_id, author.id
    assert_equal "Second Author", author.display_name
    assert_equal 1, author.position
    assert_nil project.reload.author_identities_indexed_at
    assert_nil project.author_identities_index_error
  end

  test "skips an unchanged indexed snapshot" do
    project = create_project(citation_file: one_person_cff)
    ProjectCitationAuthorIndexer.new(project).sync!
    author = project.project_authors.first
    indexed_at = project.reload.citation_authors_indexed_at
    updated_at = author.updated_at

    travel 1.minute do
      result = ProjectCitationAuthorIndexer.new(project).sync!

      assert_not result.fetch(:indexed)
      assert_equal indexed_at, project.reload.citation_authors_indexed_at
      assert_equal updated_at, author.reload.updated_at
    end
  end

  test "reindexes an old parser version" do
    project = create_project(citation_file: one_person_cff)
    ProjectCitationAuthorIndexer.new(project).sync!
    project.update_columns(citation_authors_index_version: 0)

    result = ProjectCitationAuthorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_equal ProjectCitationAuthorIndexer::CURRENT_VERSION,
      project.reload.citation_authors_index_version
  end

  test "records parse errors and retains the last successful snapshot" do
    project = create_project(citation_file: one_person_cff)
    ProjectCitationAuthorIndexer.new(project).sync!
    original_author = project.project_authors.first.attributes
    project.update!(citation_file: "cff-version: 1.2.0\ntitle: [\n")

    result = ProjectCitationAuthorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:failed)
    assert_equal 0, result.fetch(:indexed)
    assert_match "Psych::SyntaxError", project.reload.citation_authors_index_error
    assert_equal ProjectCitationAuthorIndexer::CURRENT_VERSION,
      project.citation_authors_index_version
    assert_equal Digest::SHA256.hexdigest(project.citation_file),
      project.citation_authors_source_digest
    assert_equal original_author,
      project.project_authors.first.attributes
    assert_equal 0,
      ProjectCitationAuthorIndexer.sync_batch!(limit: 1).fetch(:selected)
  end

  test "retries an error recorded by an older parser version" do
    project = create_project(citation_file: "cff-version: 1.2.0\ntitle: [\n")
    ProjectCitationAuthorIndexer.sync_batch!(limit: 1)
    project.update_columns(citation_authors_index_version: 0)

    result = ProjectCitationAuthorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:failed)
    assert_equal ProjectCitationAuthorIndexer::CURRENT_VERSION,
      project.reload.citation_authors_index_version
  end

  test "clears authors after the CFF source is removed" do
    project = create_project(citation_file: full_cff)
    ProjectCitationAuthorIndexer.new(project).sync!
    AuthorIdentityIndexer.new(project).sync!
    authors = project.project_authors.reload.filter_map(&:author).uniq
    assert_equal [1], authors.map(&:public_evidence_count)
    project.update!(citation_file: nil)

    result = ProjectCitationAuthorIndexer.new(project).sync!

    assert result.fetch(:indexed)
    assert_empty project.project_authors
    assert project.reload.citation_authors_indexed_at.present?
    assert_equal [0], authors.map { |author| author.reload.public_evidence_count }
  end

  test "processes a bounded batch of visible scientific projects" do
    first = create_project(citation_file: one_person_cff)
    second = create_project(citation_file: one_person_cff)
    create_project(citation_file: one_person_cff, science_score: 19)

    result = ProjectCitationAuthorIndexer.sync_batch!(limit: 1)

    assert_equal 1, result.fetch(:selected)
    assert_equal 1, result.fetch(:indexed)
    assert_equal 1,
      Project.where.not(citation_authors_indexed_at: nil).where(id: [first.id, second.id]).count
  end

  test "rejects an invalid batch limit" do
    error = assert_raises(ArgumentError) do
      ProjectCitationAuthorIndexer.sync_batch!(limit: 0)
    end

    assert_equal "limit must be between 1 and 1000", error.message
  end

  def create_project(citation_file:, science_score: 20)
    @project_number = @project_number.to_i + 1
    Project.create!(
      url: "https://github.com/test/cff-index-#{@project_number}",
      science_score: science_score,
      citation_file: citation_file
    )
  end

  def full_cff
    <<~CFF
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: Ada
          family-names: Lovelace
          email: ADA@EXAMPLE.EDU
          orcid: https://orcid.org/0000-0002-1825-0097
          affiliation: Example University
        - name: Example Research Group
          email: group@example.edu
          orcid: 0000-0002-1825-0097
      preferred-citation:
        type: article
        title: Example Paper
        authors:
          - given-names: Grace
            family-names: Hopper
            orcid: 0000-0002-1825-0098
    CFF
  end

  def two_person_cff
    <<~CFF
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: First
          family-names: Author
        - given-names: Second
          family-names: Author
    CFF
  end

  def one_person_cff
    <<~CFF
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: Second
          family-names: Author
    CFF
  end
end
