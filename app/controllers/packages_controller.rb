class PackagesController < ApplicationController
  def index
    index = PackageIndex.new(params)
    @fields = index.fields
    @domains = index.domains
    @ecosystems = index.ecosystems
    @selected_ecosystem = index.selected_ecosystem
    @selected_domain = index.selected_domain
    @selected_field = index.selected_field
    @selected_sort = index.selected_sort
    @sort_options = index.sort_options
    @pagy, @packages = pagy(index.scope, limit: 20)
  end
end
