class JevDiscoveriesController < ApplicationController
  before_action :authenticate_operator
  protect_from_forgery with: :exception

  def index
    @runs = JevRun.order(id: :desc).limit(20)
    @run = params[:run_id].present? ? JevRun.find(params[:run_id]) : @runs.first
    @statistics = @run&.statistics
    scope = @run ? @run.jev_discoveries : JevDiscovery.none
    %w[classification status review_state sample_group screen_band].each do |key|
      scope = scope.where(key => params[key]) if params[key].present?
    end
    scope = scope.where(control: true) if params[:controls] == "1"
    if params[:q].present?
      scope = scope.where("repository_url ILIKE ?", "%#{JevDiscovery.sanitize_sql_like(params[:q])}%")
    end
    @pagy, @discoveries = pagy(scope.order(id: :desc), limit: 50)
  end

  def show
    @discovery = JevDiscovery.includes(:jev_run, :screen_request, :enrich_request).find(params[:id])
  end

  def update
    @discovery = JevDiscovery.find(params[:id])
    @discovery.review!(state: params.require(:jev_discovery).fetch(:review_state),
      notes: params[:jev_discovery][:review_notes], reviewer: @operator)
    redirect_to jev_discovery_path(@discovery), notice: "Discovery review saved."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_entity
  end

  def authenticate_operator
    username = ENV["SIDEKIQ_USERNAME"]
    password = ENV["SIDEKIQ_PASSWORD"]
    return head :service_unavailable if username.blank? || password.blank?
    authenticate_or_request_with_http_basic("Discovery review") do |supplied_user, supplied_password|
      valid = ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(supplied_user), Digest::SHA256.hexdigest(username)) &
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(supplied_password), Digest::SHA256.hexdigest(password))
      @operator = supplied_user if valid
      valid
    end
  end
end
