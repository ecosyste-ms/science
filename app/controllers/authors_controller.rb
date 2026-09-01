class AuthorsController < ApplicationController
  PROJECTS_PER_SECTION = 20
  ACCOUNTS_PER_PAGE = 20

  def index
    scope = Author
      .with_public_evidence
      .alphabetical
      .includes(:public_identifiers)
    @pagy, @authors = pagy(scope)
    @role_counts = Author.role_counts(@authors.map(&:id))
  end

  def show
    @author = Author
      .with_public_evidence
      .includes(:public_identifiers)
      .find(params[:id])

    @software_pagy, @software_projects = pagy(
      @author.software_projects,
      limit: PROJECTS_PER_SECTION,
      page_param: :software_page
    )
    @citation_pagy, @citation_projects = pagy(
      @author.preferred_citation_projects,
      limit: PROJECTS_PER_SECTION,
      page_param: :citation_page
    )
    @contribution_pagy, @contributed_projects = pagy(
      @author.contributed_projects,
      limit: PROJECTS_PER_SECTION,
      page_param: :contribution_page
    )
    @account_pagy, @developer_accounts = pagy(
      @author.public_developer_accounts,
      limit: ACCOUNTS_PER_PAGE,
      page_param: :account_page
    )
    @contribution_counts = @author.project_contributors
      .where(project_id: @contributed_projects.map(&:id))
      .group(:project_id)
      .sum(:contributions_count)
  end
end
