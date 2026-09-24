class Api::V1::PackagesController < Api::V1::ApplicationController
  def bulk_lookup
    @packages = Package.bulk_lookup(params[:purls])
    render :index
  rescue ArgumentError => error
    render json: { error: error.message }, status: :bad_request
  end

  def index
    index = PackageIndex.new(params)
    @pagy, @packages = pagy(index.scope)
  end
end
