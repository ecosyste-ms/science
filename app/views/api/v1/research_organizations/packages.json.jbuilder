json.array! @packages do |package|
  json.extract! package, :id, :name, :purl, :namespace
  json.registry do
    json.extract! package.package_registry, :name, :ecosystem
  end
  json.published_by_project do
    json.id package.published_by_project.id
    json.repository_url package.published_by_project.url
    json.api_url api_v1_project_url(package.published_by_project)
    json.html_url project_url(package.published_by_project)
  end
end
