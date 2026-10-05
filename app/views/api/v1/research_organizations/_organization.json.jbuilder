json.id organization.to_param
json.ror_id organization.ror_id
json.name organization.display_name
json.names organization.metadata.fetch("names", [])
json.status organization.metadata["status"]
json.countries organization.countries
json.source do
  json.version organization.current_import.source_version
  json.retrieved_at organization.current_import.retrieved_at
  json.current organization.current_import.current?
  json.backfill_complete organization.current_import.backfill_completed_at.present?
end
json.html_url research_organization_url(organization)
json.api_url api_v1_research_organization_url(organization)
