class PackagesController < ApplicationController
  def index
    @fields = Field.open_alex.order(:domain, :name).to_a
    @domains = @fields.map(&:domain_display_name).uniq.sort.map do |name|
      { name: name, slug: name.parameterize }
    end
    @ecosystems = Package.scientific_dependency_ecosystems
    @selected_ecosystem = @ecosystems.find do |ecosystem|
      ecosystem == params[:ecosystem].to_s.downcase
    end
    @selected_domain = @domains.find do |domain|
      domain.fetch(:slug) == params[:domain].to_s
    end
    @selected_field = @fields.find do |field|
      field.to_param == params[:field].to_s
    end

    scope = Package.ranked_by_scientific_dependents(
      field_ids: selected_field_ids
    )
    if @selected_ecosystem
      scope = scope.joins(:package_registry).where(
        package_registries: { ecosystem: @selected_ecosystem }
      )
    end
    @pagy, @packages = pagy(scope, limit: 20)
  end

  def selected_field_ids
    filters = []
    if @selected_domain
      filters << @fields.select do |field|
        field.domain_display_name == @selected_domain.fetch(:name)
      end.map(&:id)
    end
    filters << [@selected_field.id] if @selected_field
    return if filters.empty?

    filters.reduce { |ids, filter| ids & filter }
  end
end
