json.extract! candidate, :id, :project_id, :repository_url, :source, :sampling_method, :sample_group,
  :status, :classification, :strict_probability, :implementation_probability, :screen_band,
  :control, :control_probability, :enrichment_selected, :enrichment_reason, :evidence_fingerprint,
  :screened_at, :enriched_at, :review_state, :review_purpose, :review_implementation,
  :review_catalogue_value, :reviewed_at, :created_at, :updated_at
json.run_id candidate.jev_run_id
json.shadow true
json.evidence_incomplete candidate.enrichment_error.present?
json.repository_identity_status candidate.evidence.dig("repository_identity", "status")
json.url api_v1_discovery_candidate_url(candidate)
json.run_url api_v1_discovery_run_url(candidate.jev_run_id)
