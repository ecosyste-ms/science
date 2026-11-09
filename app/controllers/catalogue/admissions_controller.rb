class Catalogue::AdmissionsController < ApplicationController
  include OperatorAuthentication
  before_action :load_project, except: :index

  def index
    if params[:project_id].present?
      project = Project.visible.find(params[:project_id])
      return redirect_to project_admission_path(project)
    end
    scope = Catalogue::Admission.includes(:project).order(reviewed_at: :desc, id: :desc)
    scope = scope.where(decision: params[:decision]) if params[:decision].present?
    @counts = Catalogue::Admission.group(:decision).count
    @new_entries = Catalogue::Admission.new_entries.where(project_id: Project.visible.select(:id)).count
    @pagy, @admissions = pagy_countless(scope, limit: 50)
  end

  def show
    @admission = @stored_admission || Catalogue::Admission.new(project: @project)
    @source_id = params[:source_discovery_id].presence || @admission.source_discovery_id
  end

  def create
    values = params.require(:catalogue_admission).permit(:decision, :reason, :source_discovery_id)
    source = Jev::Discovery.publicly_accessible.find(values[:source_discovery_id]) if values[:source_discovery_id].present?
    @admission = Catalogue::Admission.record!(project: @project, decision: values[:decision], reason: values[:reason],
      reviewer: @operator, source_discovery: source)
    redirect_to project_admission_path(@project), notice: "Catalogue decision saved."
  rescue ActiveRecord::RecordInvalid => error
    @admission = error.record
    @source_id = values[:source_discovery_id]
    render :show, status: :unprocessable_entity
  end

  def update
    create
  end

  def load_project
    @project = Project.visible.includes(:catalogue_admission).find(params[:project_id])
    @stored_admission = @project.catalogue_admission
  end
end
