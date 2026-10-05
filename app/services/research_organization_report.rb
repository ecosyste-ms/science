class ResearchOrganizationReport
  attr_reader :organization, :include_descendants

  def self.boolean(value, default: false)
    return default if value.nil?
    return true if value == true || value == "true"
    return false if value == false || value == "false"
    raise ArgumentError, "boolean parameters must be true or false"
  end

  def initialize(organization, include_descendants: false)
    @organization = organization
    @include_descendants = include_descendants
  end

  def organizations
    records = ResearchOrganization.where(id: organization.id)
    include_descendants ? records.or(ResearchOrganization.where(id: organization.descendants.select(:id))) : records
  end

  def links
    OwnerResearchOrganization.joins(:owner).merge(Owner.visible)
      .where(research_organization_id: organizations.select(:id), relationship: "repository_owner")
  end

  def accounts
    Owner.visible.where(id: links.where(match_status: "matched").select(:owner_id))
      .includes(:host).order(Arel.sql("LOWER(owners.login)"), :id)
  end

  def projects
    Project.visible.scientific.where(owner_id: accounts.reselect(:id).reorder(nil))
      .includes(:host, :owner_record, project_fields: :field).order(science_score: :desc, id: :asc)
  end

  def packages
    Package.where(published_by_project_id: projects.reselect(:id).reorder(nil))
      .includes(:package_registry, :published_by_project).order(Arel.sql("LOWER(packages.name)"), :id)
  end

  def counts
    @counts ||= { organizations: organizations.count, accounts: accounts.count,
      scientific_projects: projects.count, packages: packages.count,
      ambiguous_accounts: links.where(match_status: "ambiguous").distinct.count(:owner_id) }
  end
end
