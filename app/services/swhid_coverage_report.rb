class SwhidCoverageReport
  def self.counts
    eligible = Project.visible.scientific.with_repository
    coverage = eligible.group(Arel.sql("COALESCE(swhids->'origin_archive'->>'status', 'unchecked')")).count
    requests = eligible.where("swhids->'archival'->>'id' IS NOT NULL AND swhids->'archival'->>'attribution_eligible' = 'true'")
    classification = Arel.sql("COALESCE(swhids->'archival'->'repository_before_request'->>'classification', 'unknown')")
    submitted = requests.group(classification).count
    imported = requests.where("swhids->'archival'->>'save_task_status' = 'succeeded'").group(classification).count
    {
      "eligible_projects" => coverage.values.sum,
      "repository_coverage" => %w[archived not_found unknown unchecked].to_h { |status| [status, coverage.fetch(status, 0)] },
      "submitted_projects" => %w[missing_versions missing_repository unknown].to_h { |kind| [kind, submitted.fetch(kind, 0)] },
      "submission_evidence" => requests.group(Arel.sql("COALESCE(swhids->'archival'->'repository_before_request'->>'basis', 'unknown')")).count,
      "imported_projects" => %w[missing_versions missing_repository unknown].to_h { |kind| [kind, imported.fetch(kind, 0)] }
    }
  end
end
