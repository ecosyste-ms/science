class Author < ApplicationRecord
  has_many :identifiers,
    class_name: "AuthorIdentifier",
    dependent: :delete_all
  has_many :public_identifiers,
    -> { publicly_displayable.order(:scheme, :value) },
    class_name: "AuthorIdentifier"
  has_many :project_authors, dependent: :nullify
  has_many :paper_authors, dependent: :nullify
  has_many :project_contributors, dependent: :nullify
  has_many :developer_account_links,
    class_name: "AuthorDeveloperAccountLink",
    dependent: :delete_all
  has_many :developer_accounts,
    through: :developer_account_links

  validates :canonical_key,
    presence: true,
    uniqueness: { case_sensitive: false }

  scope :with_public_evidence, -> { where("public_evidence_count > 0") }
  scope :alphabetical, -> {
    order(Arel.sql(
      "LOWER(COALESCE(NULLIF(BTRIM(display_name), ''), canonical_key::text)), id"
    ))
  }

  def self.role_counts(author_ids)
    author_ids = author_ids.map(&:to_i).uniq
    counts = author_ids.index_with do
      {
        software_projects: 0,
        preferred_citation_projects: 0,
        contributed_projects: 0,
        authored_papers: 0,
        edited_papers: 0,
      }
    end
    return counts if author_ids.empty?

    public_project_ids = Project.visible.scientific.select(:id)
    ProjectAuthor
      .where(author_id: author_ids, project_id: public_project_ids)
      .group(:author_id, :authorship_kind)
      .distinct
      .count(:project_id)
      .each do |(author_id, authorship_kind), count|
        key = authorship_kind == "software" ?
          :software_projects : :preferred_citation_projects
        counts.fetch(author_id)[key] = count
      end

    ProjectContributor
      .where(author_id: author_ids, project_id: public_project_ids)
      .group(:author_id)
      .distinct
      .count(:project_id)
      .each do |author_id, count|
        counts.fetch(author_id)[:contributed_projects] = count
      end

    PaperAuthor
      .joins(paper: :mentions)
      .where(
        author_id: author_ids,
        mentions: { project_id: public_project_ids }
      )
      .group(:author_id, :role)
      .distinct
      .count(:paper_id)
      .each do |(author_id, role), count|
        key = role == "editor" ? :edited_papers : :authored_papers
        counts.fetch(author_id)[key] = count
      end

    counts
  end

  def software_projects
    projects_for_authorship("software")
  end

  def preferred_citation_projects
    projects_for_authorship("preferred_citation")
  end

  def contributed_projects
    Project.visible
      .scientific
      .where(id: project_contributors.select(:project_id))
      .order(Arel.sql(
        "projects.science_score DESC NULLS LAST, " \
          "LOWER(COALESCE(projects.name, projects.url)), projects.id"
      ))
  end

  def authored_papers
    papers_for_role("author")
  end

  def edited_papers
    papers_for_role("editor")
  end

  def public_developer_accounts
    DeveloperAccount
      .merge(DeveloperAccount.public_people)
      .where(
        id: developer_account_links
          .where(deterministic: true)
          .select(:developer_account_id)
      )
      .where(
        id: AuthorDeveloperAccountLink.unambiguous_account_ids_for(id)
      )
      .includes(:host, :owner)
      .order(Arel.sql(
        "LOWER(COALESCE(developer_accounts.login, " \
          "developer_accounts.name, developer_accounts.canonical_key::text)), " \
          "developer_accounts.id"
      ))
  end

  def projects_for_authorship(authorship_kind)
    project_ids = project_authors
      .where(authorship_kind: authorship_kind)
      .select(:project_id)
    Project.visible
      .scientific
      .where(id: project_ids)
      .order(Arel.sql(
        "projects.science_score DESC NULLS LAST, " \
          "LOWER(COALESCE(projects.name, projects.url)), projects.id"
      ))
  end

  def papers_for_role(role)
    paper_ids = paper_authors.where(role: role).select(:paper_id)
    public_project_ids = Project.visible.scientific.select(:id)
    mentioned_paper_ids = Mention
      .where(project_id: public_project_ids)
      .select(:paper_id)
    Paper
      .where(id: paper_ids)
      .where(id: mentioned_paper_ids)
      .order(Arel.sql(
        "papers.publication_date DESC NULLS LAST, " \
          "LOWER(COALESCE(papers.title, papers.doi)), papers.id"
      ))
  end

  def to_s
    display_name.presence || "Unnamed author"
  end
end
