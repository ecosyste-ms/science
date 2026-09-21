class SoftwareSearchIndexer
  def self.index(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    project.with_lock do
      values = {}
      if project.science_score.to_f >= Project::SCIENCE_SCORE_THRESHOLD
        document = ProjectSearchSeeds.new(project).as_json
        seeds = document[:seeds] + document[:packages].flat_map { |package| package[:seeds] }
        values = seeds.group_by { |seed| seed[:type] }
          .transform_values { |items| items.pluck(:normalized_value).uniq.sort }
        values["purl"] = document[:packages].pluck(:purl).compact.uniq.sort
      end
      project.update_columns(
        search_identifiers: values,
        search_names: Array(values["name"]).join("\n"),
        search_indexed_at: Time.current
      )
      values.values.sum(&:length)
    end
  end
end
