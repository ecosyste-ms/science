class SwhidCoverageReport
  def self.contribution_summary
    report = counts
    identifiers = SwhidArchiver.contribution_counts
    total = report.fetch("eligible_projects")
    classifications = {
      "missing_versions" => "Missing versions of previously archived repositories",
      "missing_repository" => "No repository snapshot found before submission",
      "unknown" => "Prior repository coverage unknown"
    }

    [
      "Eligible science projects: #{total}",
      "Projects with new archival requests: #{fraction(report.fetch('submitted_projects').values.sum, total)}",
      "Projects with successful imports: #{fraction(report.fetch('imported_projects').values.sum, total)}",
      "",
      *breakdown("Repository coverage among eligible projects", report.fetch("repository_coverage"), {
        "archived" => "Archived snapshot found",
        "not_found" => "No snapshot found at checked URLs",
        "unknown" => "Unknown",
        "unchecked" => "Unchecked"
      }),
      "",
      *breakdown("Submitted projects by prior repository coverage", report.fetch("submitted_projects"), classifications),
      "",
      *breakdown("Imported projects by prior repository coverage", report.fetch("imported_projects"), classifications),
      "",
      *breakdown("Submission evidence", report.fetch("submission_evidence"), {
        "pre_submission" => "Observed before submission",
        "visit_history" => "Inferred from historical visit dates",
        "unknown" => "Unknown"
      }),
      "",
      "Confirmed contributions across all recorded projects:",
      "SWHIDs archived after our request: #{identifiers.fetch('total')}",
      "Revisions: #{identifiers.fetch('revisions')}",
      "Directories: #{identifiers.fetch('directories')}"
    ].join("\n")
  end

  def self.fraction(count, total)
    percentage = total.zero? ? "n/a" : format("%.1f%%", count * 100.0 / total)
    "#{count}/#{total} (#{percentage})"
  end

  def self.breakdown(title, counts, labels)
    ["#{title}:", *labels.map { |key, label| "  #{label}: #{counts.fetch(key, 0)}" }]
  end

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
