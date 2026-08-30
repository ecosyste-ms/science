class Api::V1::PackagesController < Api::V1::ApplicationController
  def index
    index = PackageIndex.new(params)
    @pagy, @packages = pagy(index.scope)
  end
end
