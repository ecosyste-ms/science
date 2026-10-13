class PaperCandidateImporter
  def call(data)
    report = if data.is_a?(Hash) && data.key?("lookups")
      data.deep_dup
    else
      PaperIdentityResolver.new.call(data.is_a?(Hash) ? data.fetch("candidates") : data)
    end
    report.fetch("candidates").each do |row|
      row["import"] = import_candidate(row, report.fetch("lookups"))
    end
    report["import_summary"] = report["candidates"].group_by { |row| row.fetch("import").fetch("status") }.transform_values(&:size)
    report
  end

  def import_candidate(row, lookups)
    lookup = lookups[row["lookup"]]
    unless %w[metadata_agrees needs_review].include?(row["assessment"]) &&
        !row.fetch("checks", {}).values.include?(false) && lookup&.fetch("status") == "found"
      return { "status" => "skipped", "reason" => row.fetch("assessment") }
    end
    Paper.import_openalex!(lookup.fetch("work"))
  rescue ArgumentError, KeyError, ActiveRecord::RecordInvalid => error
    { "status" => "error", "reason" => error.message }
  end
end
