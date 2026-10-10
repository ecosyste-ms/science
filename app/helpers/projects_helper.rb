module ProjectsHelper
  PROJECT_FILTER_LABELS = {
    "keyword" => "Keyword",
    "language" => "Language",
    "owner" => "Owner",
    "research_organization" => "Research organizations"
  }.freeze

  def active_project_filters
    PROJECT_FILTER_LABELS.filter_map do |key, label|
      value = request.query_parameters[key]
      next if value.blank?

      [key, key == "research_organization" ? label : "#{label}: #{value}"]
    end.to_h
  end

  def project_filter_path(changes = {})
    query = request.query_parameters.except("page").merge(changes.stringify_keys).compact_blank.to_query
    query.present? ? "#{request.path}?#{query}" : request.path
  end
end
