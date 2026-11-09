class Jev::DiscoveriesController < ApplicationController
  include OperatorAuthentication

  def index
    @runs = Jev::Run.order(id: :desc).limit(20)
    @run = params[:run_id].present? ? Jev::Run.find(params[:run_id]) : @runs.first
    @statistics = @run&.statistics
    scope = @run ? @run.discoveries : Jev::Discovery.none
    %w[classification status review_state sample_group screen_band review_purpose review_implementation review_catalogue_value].each do |key|
      scope = scope.where(key => params[key]) if params[key].present?
    end
    scope = scope.where(control: true) if params[:controls] == "1"
    if params[:candidate_ids].present?
      ids = params[:candidate_ids].to_s.split(",", -1)
      return head :bad_request unless ids.size.between?(1, 100) && ids.all? { |id| id.match?(/\A[1-9]\d*\z/) && id.to_i <= 9_223_372_036_854_775_807 }
      scope = scope.where(id: ids.map(&:to_i).uniq)
    end
    scope = scope.where("evidence #>> '{repository_identity,status}' = ?", params[:identity]) if params[:identity].present?
    if params[:q].present?
      scope = scope.where("repository_url ILIKE ?", "%#{Jev::Discovery.sanitize_sql_like(params[:q])}%")
    end
    @pagy, @discoveries = pagy(scope.order(id: :desc), limit: 50)
  end

  def show
    @discovery = Jev::Discovery.includes(:run, :screen_request, :enrich_request).find(params[:id])
  end

  def update
    @discovery = Jev::Discovery.find(params[:id])
    @discovery.review!(state: params.require(:jev_discovery).fetch(:review_state),
      notes: params[:jev_discovery][:review_notes], reviewer: @operator,
      purpose: params[:jev_discovery].fetch(:review_purpose, @discovery.review_purpose),
      implementation: params[:jev_discovery].fetch(:review_implementation, @discovery.review_implementation),
      catalogue_value: params[:jev_discovery].fetch(:review_catalogue_value, @discovery.review_catalogue_value))
    redirect_to jev_discovery_path(@discovery), notice: "Discovery review saved."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_entity
  end

end
