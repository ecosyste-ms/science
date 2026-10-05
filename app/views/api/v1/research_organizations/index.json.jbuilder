json.array! @organizations do |organization|
  json.partial! "organization", organization: organization
  json.linked_accounts_count @account_counts.fetch(organization.id, 0)
end
