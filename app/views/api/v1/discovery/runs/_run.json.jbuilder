json.extract! run, :id, :name, :status, :target_count, :sampling_complete, :completed_at, :created_at, :updated_at
json.shadow true
json.model run.settings["model"]
json.question_versions run.settings["question_versions"]
json.population run.settings["population"]
json.budget_usd run.budget_usd.to_f
json.spent_usd run.spent_usd.to_f
json.reserved_usd run.reserved_usd.to_f
json.url api_v1_discovery_run_url(run)
json.candidates_url api_v1_discovery_candidates_url(run_id: run.id)
