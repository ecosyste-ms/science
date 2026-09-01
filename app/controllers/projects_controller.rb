class ProjectsController < ApplicationController
  def show
    @project = Project.visible
      .includes(:host, :owner_record, { project_fields: :field }, papers: :mentions)
      .find(params[:id])
    @joss_publication_credits = @project.joss_publication_credits
      .includes(:author)
      .to_a
  end

  def export
    @project = Project.visible.find(params[:id])
    format = params[:format] || 'bibtex'

    exported_content = @project.export_citation(format: format)

    if exported_content
      send_data exported_content,
                filename: "#{@project.name || @project.id}.#{format}",
                type: mime_type_for_format(format),
                disposition: 'attachment'
    else
      render plain: 'No citation metadata available for this project', status: :not_found
    end
  end

  def index
    scope = Project.visible.includes(project_fields: :field).where('science_score > 0')
    filtered_project_list(scope)
  end

  def search
    @scope = Project.visible.includes(project_fields: :field).where('science_score > 0')

    if params[:q].present?
      @scope = @scope.where("url ILIKE ?", "%#{params[:q]}%")
    end

    if params[:keywords].present?
      @scope = @scope.keyword(params[:keywords])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = @scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))

    @pagy, @projects = pagy(@scope, limit: 20)
  end

  def lookup
    @query = params[:q]
    @results = ProjectSearch.new(@query, 20).search if @query.present?
  end

  def packages
    @projects = Project.packages_sorted
  end

  def joss
    filtered_project_list(Project.visible.with_joss)
  end

  def codemeta
    filtered_project_list(Project.visible.with_codemeta_file)
  end

  def citation
    filtered_project_list(Project.visible.with_citation_file)
  end

  def zenodo
    filtered_project_list(Project.visible.with_zenodo_file)
  end

  def codemeta_csv
    send_project_csv(Project.visible.with_codemeta_file, 'codemeta', :codemeta_file_name)
  end

  def citation_csv
    send_project_csv(Project.visible.with_citation_file, 'citation', :citation_file_name)
  end

  def zenodo_csv
    send_project_csv(Project.visible.with_zenodo_file, 'zenodo', :zenodo_file_name)
  end

  def filtered_project_list(scope)
    scope = scope.includes(project_fields: :field)
    scope = scope.keyword(params[:keyword]) if params[:keyword].present?
    scope = scope.owner(params[:owner]) if params[:owner].present?
    scope = scope.language(params[:language]) if params[:language].present?
    scope = scope.with_research_organization_owner if params[:research_organization].present?
    @scope = apply_project_sort(scope)
    @pagy, @projects = pagy(@scope)
  end

  def send_project_csv(scope, name, file_column)
    csv_data = CSV.generate(headers: true) do |csv|
      csv << ['repository_url', "#{name}_file_path"]
      scope.find_each do |project|
        csv << [project.repository_url, project.public_send(file_column)]
      end
    end

    send_data csv_data,
              filename: "projects_with_#{name}_#{Date.current}.csv",
              type: 'text/csv',
              disposition: 'attachment'
  end

  def apply_project_sort(scope)
    if params[:sort].present? || params[:order].present?
      sort = sanitize_sort(Project.sortable_columns, default: 'science_score')
      scope.order(sort.public_send(sanitize_order).nulls_last)
    else
      scope.order(Arel.sql('(science_score + COALESCE(score, 0)) DESC'))
    end
  end

  def mime_type_for_format(format)
    case format
    when 'bibtex' then 'application/x-bibtex'
    when 'apalike', 'apa' then 'text/plain'
    else 'text/plain'
    end
  end
end
