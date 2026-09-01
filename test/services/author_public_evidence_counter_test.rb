require "test_helper"

class AuthorPublicEvidenceCounterTest < ActiveSupport::TestCase
  setup do
    @host = Host.create!(name: "Evidence GitHub")
  end

  test "counts linked observations from visible scientific projects" do
    author = create_author("Public Author")
    hidden_author = create_author("Hidden Author")
    project = create_project("public")
    hidden_owner = Owner.create!(host: @host, login: "hidden-owner")
    hidden_project = create_project("hidden", owner: hidden_owner)
    low_project = create_project(
      "low",
      science_score: Project::SCIENCE_SCORE_THRESHOLD - 1
    )

    create_project_author(author, project)
    create_project_contributor(author, project)
    paper = Paper.create!(doi: "10.21105/joss.12345")
    Mention.create!(paper: paper, project: project)
    Mention.create!(paper: paper, project: hidden_project)
    create_paper_author(author, paper)
    create_project_author(hidden_author, hidden_project)
    create_project_contributor(hidden_author, low_project)
    hidden_owner.update_column(:hidden, true)

    result = AuthorPublicEvidenceCounter.refresh!([author.id, hidden_author.id])

    assert_equal({ authors: 2, updated: 1 }, result)
    assert_equal 3, author.reload.public_evidence_count
    assert_equal 0, hidden_author.reload.public_evidence_count
    assert_equal [author], Author.with_public_evidence.to_a
  end

  test "project and owner visibility changes refresh linked authors" do
    author = create_author("Threshold Author")
    project = create_project("threshold")
    create_project_author(author, project)
    AuthorPublicEvidenceCounter.refresh!([author.id])

    project.update!(science_score: Project::SCIENCE_SCORE_THRESHOLD - 1)
    assert_equal 0, author.reload.public_evidence_count

    project.update!(science_score: Project::SCIENCE_SCORE_THRESHOLD)
    assert_equal 1, author.reload.public_evidence_count

    owner = Owner.create!(host: @host, login: "visibility-owner")
    project.update!(owner_record: owner)
    owner.update!(hidden: true)

    assert_equal 0, author.reload.public_evidence_count
  end

  test "destroying a project refreshes linked authors" do
    author = create_author("Removed Author")
    project = create_project("removed")
    create_project_author(author, project)
    AuthorPublicEvidenceCounter.refresh!([author.id])

    project.destroy!

    assert_equal 0, author.reload.public_evidence_count
  end

  test "sync batch uses an id cursor and bounded limit" do
    authors = 3.times.map { |index| create_author("Author #{index}") }
    authors.each_with_index do |author, index|
      create_project_author(author, create_project("batch-#{index}"))
    end

    first = AuthorPublicEvidenceCounter.sync_batch!(limit: 2)
    second = AuthorPublicEvidenceCounter.sync_batch!(
      limit: 2,
      after_id: first.fetch(:next_after_id)
    )

    assert_equal 2, first.fetch(:selected)
    assert_not first.fetch(:complete)
    assert_equal 1, second.fetch(:selected)
    assert second.fetch(:complete)
    assert_equal [1, 1, 1], authors.map { |author| author.reload.public_evidence_count }
  end

  def create_author(name)
    Author.create!(
      canonical_key: "email:#{name.parameterize}@example.edu",
      display_name: name
    )
  end

  def create_project(key, owner: nil, science_score: 60)
    Project.create!(
      url: "https://github.com/evidence/#{key}",
      owner_record: owner,
      science_score: science_score
    )
  end

  def create_project_author(author, project)
    ProjectAuthor.create!(
      project: project,
      author: author,
      source: "citation_cff",
      authorship_kind: "software",
      author_kind: "person",
      position: 1,
      display_name: author.display_name,
      source_path: "authors[0]",
      source_digest: "project-author-#{project.id}"
    )
  end

  def create_project_contributor(author, project)
    ProjectContributor.create!(
      project: project,
      author: author,
      source: "commits_ecosyste_ms",
      source_key: "contributor-#{project.id}",
      account_kind: "unknown",
      contributions_count: 1,
      source_digest: "project-contributor-#{project.id}"
    )
  end

  def create_paper_author(author, paper)
    PaperAuthor.create!(
      paper: paper,
      author: author,
      source: "joss",
      role: "author",
      position: 1,
      display_name: author.display_name,
      source_path: "authors[0]",
      source_digest: "paper-author-#{paper.id}"
    )
  end
end
