class Jev::DiscoveryQuery
  FILTERS = %w[classification status sample_group screen_band review_state review_purpose review_implementation review_catalogue_value].freeze

  def initialize(params)
    @params = params
  end

  def scope
    records = Jev::Discovery.publicly_accessible
    %w[run_id project_id].each do |key|
      next unless @params[key].present?
      value = integer(key)
      column = key == "run_id" ? :jev_run_id : :project_id
      records = records.where(column => value)
    end
    FILTERS.each { |key| records = records.where(key => @params[key]) if @params[key].present? }
    if @params[:repository_url].present?
      url = Jev::Evidence.repository_url(@params[:repository_url])
      raise ArgumentError, "repository_url must be a supported HTTPS repository URL" unless url
      records = records.where(repository_url: url)
    end
    if @params[:control].present?
      raise ArgumentError, "control must be true or false" unless %w[true false].include?(@params[:control].to_s)
      records = records.where(control: @params[:control].to_s == "true")
    end
    records = records.where("jev_discoveries.id > ?", integer("after_id")) if @params[:after_id].present?
    records.order(:id)
  end

  def integer(key)
    value = @params[key].to_s
    raise ArgumentError, "#{key} must be a positive integer" unless value.match?(/\A[1-9]\d{0,17}\z/)
    value.to_i
  end

  def page_limit
    return 100 if @params[:per_page].blank?
    value = integer("per_page")
    raise ArgumentError, "per_page must be between 1 and 100" unless value <= 100
    value
  end
end
