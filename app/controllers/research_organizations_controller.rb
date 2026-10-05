class ResearchOrganizationsController < ApplicationController
  before_action :load_report, only: %i[show owners projects packages]
  rescue_from ArgumentError, with: :invalid_parameters

  def index
    @index = ResearchOrganizationIndex.new(params)
    @pagy, @organizations = pagy(@index.scope, limit: ResearchOrganizationIndex.page_limit(params), limit_extra: false)
    @account_counts = OwnerResearchOrganization.confirmed.where(research_organization_id: @organizations.map(&:id))
      .group(:research_organization_id).distinct.count(:owner_id)
  end

  def show
    projects
  end

  def owners
    @section = "owners"
    @pagy, @accounts = pagy(@report.accounts, limit: ResearchOrganizationIndex.page_limit(params), limit_extra: false)
    @account_list = ResearchOrganizationAccountList.new(@accounts, links: @report.links.where(match_status: "matched"))
    render :show
  end

  def projects
    @section = "projects"
    @pagy, @projects = pagy(@report.projects, limit: ResearchOrganizationIndex.page_limit(params), limit_extra: false)
    render :show
  end

  def packages
    @section = "packages"
    @pagy, @packages = pagy(@report.packages, limit: ResearchOrganizationIndex.page_limit(params), limit_extra: false)
    render :show
  end

  def load_report
    @organization = ResearchOrganization.available.includes(:current_import).find_by!(ror_id: "https://ror.org/#{params[:id]}")
    @report = ResearchOrganizationReport.new(@organization,
      include_descendants: ResearchOrganizationReport.boolean(params[:include_descendants]))
    @counts = @report.counts
  end

  def invalid_parameters(error)
    render plain: error.message, status: :bad_request
  end
end
