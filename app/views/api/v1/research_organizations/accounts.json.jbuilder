json.array! @accounts do |account|
  json.extract! account, :id, :login, :name, :kind, :website
  json.host account.host.name
  json.html_url host_owner_url(account.host.name, account.login)
  json.scientific_projects_count @account_list.project_counts.fetch(account.id, 0)
  json.organization_matches @account_list.evidence.fetch(account.id, []) do |link|
    json.ror_id link.research_organization.ror_id
    json.extract! link, :source, :relationship, :match_method, :match_status, :evidence, :observed_at
  end
end
