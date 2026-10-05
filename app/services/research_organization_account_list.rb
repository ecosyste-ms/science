class ResearchOrganizationAccountList
  attr_reader :accounts, :evidence, :project_counts

  def initialize(accounts, links: OwnerResearchOrganization.confirmed)
    @accounts = accounts
    ids = accounts.map(&:id)
    @evidence = links.where(owner_id: ids).includes(:research_organization).group_by(&:owner_id)
    @project_counts = Project.visible.scientific.where(owner_id: ids).group(:owner_id).count
  end
end
