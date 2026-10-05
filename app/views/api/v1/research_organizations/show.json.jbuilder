json.partial! "organization", organization: @organization
json.metadata @organization.metadata
json.include_descendants @report.include_descendants
json.counts @report.counts
json.coverage do
  json.relationship "repository_owner"
  json.science_score_threshold Project::SCIENCE_SCORE_THRESHOLD
  json.ambiguous_links_included false
  json.description "Visible scientific projects owned by confirmed accounts, and packages associated with those projects. Account links do not establish institutional authorship."
end
json.links do
  json.owners owners_api_v1_research_organization_url(@organization, include_descendants: @report.include_descendants)
  json.projects projects_api_v1_research_organization_url(@organization, include_descendants: @report.include_descendants)
  json.packages packages_api_v1_research_organization_url(@organization, include_descendants: @report.include_descendants)
end
