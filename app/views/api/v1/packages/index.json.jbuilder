json.array! @packages do |package|
  json.extract! package,
    :id,
    :name,
    :namespace,
    :purl,
    :repository_url
  json.description package.metadata["description"]
  json.registry do
    json.name package.package_registry.name
    json.ecosystem package.package_registry.ecosystem
  end
  json.scientific_projects_count package.scientific_dependents_count.to_i
  json.dependent_repositories_count package.general_dependent_repositories_count&.to_i
  json.dependent_repositories_top_percentage package.dependent_repositories_top_percentage&.to_f
  json.average_top_percentage package.average_top_percentage&.to_f
  json.science_usage_percentage package.science_usage_percentage&.to_f
  json.rankings package.metadata["rankings"] || {}
  if package.published_by_project
    json.published_by_project do
      json.id package.published_by_project.id
      json.name package.published_by_project.name
      json.repository_url package.published_by_project.url
      json.api_url api_v1_project_url(package.published_by_project)
      json.html_url project_url(package.published_by_project)
    end
  else
    json.published_by_project nil
  end
end
