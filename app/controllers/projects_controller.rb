class ProjectsController < ApplicationController
  def show
    @project = Project.visible.includes(:host, :owner_record, papers: :mentions).find(params[:id])
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
    @scope = Project.visible.includes(project_fields: :field).where('science_score > 0')

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:owner].present?
      @scope = @scope.owner(params[:owner])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = apply_project_sort(@scope)

    @pagy, @projects = pagy(@scope)
  end

  def search
    @scope = Project.visible.where('science_score > 0')

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
    @scope = Project.visible.where("joss_metadata IS NOT NULL")

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = apply_project_sort(@scope)

    @pagy, @projects = pagy(@scope)
  end

  def codemeta
    @scope = Project.visible.with_codemeta_file

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = apply_project_sort(@scope)

    @pagy, @projects = pagy(@scope)
  end

  def citation
    @scope = Project.visible.with_citation_file

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = apply_project_sort(@scope)

    @pagy, @projects = pagy(@scope)
  end

  def codemeta_csv
    projects = Project.visible.with_codemeta_file

    csv_data = CSV.generate(headers: true) do |csv|
      csv << ['repository_url', 'codemeta_file_path']
      projects.find_each do |project|
        csv << [project.repository_url, project.codemeta_file_name]
      end
    end

    send_data csv_data,
              filename: "projects_with_codemeta_#{Date.current}.csv",
              type: 'text/csv',
              disposition: 'attachment'
  end

  def citation_csv
    projects = Project.visible.with_citation_file

    csv_data = CSV.generate(headers: true) do |csv|
      csv << ['repository_url', 'citation_file_path']
      projects.find_each do |project|
        csv << [project.repository_url, project.citation_file_name]
      end
    end

    send_data csv_data,
              filename: "projects_with_citation_#{Date.current}.csv",
              type: 'text/csv',
              disposition: 'attachment'
  end

  def zenodo
    @scope = Project.visible.with_zenodo_file

    if params[:keyword].present?
      @scope = @scope.keyword(params[:keyword])
    end

    if params[:language].present?
      @scope = @scope.language(params[:language])
    end

    @scope = apply_project_sort(@scope)

    @pagy, @projects = pagy(@scope)
  end

  def zenodo_csv
    projects = Project.visible.with_zenodo_file

    csv_data = CSV.generate(headers: true) do |csv|
      csv << ['repository_url', 'zenodo_file_path']
      projects.find_each do |project|
        csv << [project.repository_url, project.zenodo_file_name]
      end
    end

    send_data csv_data,
              filename: "projects_with_zenodo_#{Date.current}.csv",
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
