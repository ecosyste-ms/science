class PackageRepositoryRelationships
  def initialize(package)
    @package = package
  end

  def scope
    @package.linked_projects
      .or(Project.where(id: @package.package_projects.select(:project_id))).visible
  end

  def for_projects(projects)
    projects = projects.to_a
    project_ids = projects.map(&:id)
    direct_links = @package.package_projects.where(project_id: project_ids).order(:id).group_by(&:project_id)
    package_links = @package.package_papers.where(role: PackagePaper::MODEL_ROLES)
    project_links = ProjectPaper.where(project_id: project_ids, paper_id: package_links.select(:paper_id), role: "implementation")
      .includes(:paper).order(:id).to_a
    package_links_by_paper = package_links.where(paper_id: project_links.map(&:paper_id)).order(:id).group_by(&:paper_id)
    project_links_by_project = project_links.group_by(&:project_id)

    projects.map do |project|
      relationships = Array(direct_links[project.id]).map do |link|
        { type: "direct", role: link.role, evidence: link.evidence }
      end
      Array(project_links_by_project[project.id]).each do |project_link|
        package_links_by_paper.fetch(project_link.paper_id).each do |package_link|
          paper = project_link.paper
          relationships << {
            type: "paper", role: package_link.role,
            paper: { id: paper.id, openalex_id: paper.openalex_id, doi: paper.doi, title: paper.title },
            package_evidence: package_link.evidence, project_evidence: project_link.evidence
          }
        end
      end
      { id: project.id, repository_url: project.url, relationships: relationships }
    end
  end
end
