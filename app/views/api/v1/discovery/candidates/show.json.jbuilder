json.partial! "api/v1/discovery/candidates/candidate", candidate: @candidate
json.evidence @candidate.evidence.slice("metadata", "enriched", "revision", "readme_path", "brief_version",
  "skipped_large_files", "skipped_file_paths", "skipped_file_paths_truncated", "skipped_file_types",
  "source_paths_complete", "collection_ms", "collected_at", "checkout_error")
json.evaluations do
  { screen: @candidate.screen_request, enrich: @candidate.enrich_request }.each do |stage, evaluation|
    json.set! stage do
      if evaluation
        json.extract! evaluation, :id, :model, :status, :digest, :question_versions, :input_tokens,
          :output_tokens, :attempts, :latency_ms, :completed_at
        json.cost_usd evaluation.cost_usd.to_f
        json.questions evaluation.request_body["questions"]
        json.input evaluation.request_body["state"]
        json.answers evaluation.response_body["answers"]
      else
        json.null!
      end
    end
  end
end
