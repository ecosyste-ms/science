class ApplicationController < ActionController::Base
  skip_forgery_protection
  include Pagy::Backend

  def default_url_options(options = {})
    Rails.env.production? ? { :protocol => "https" }.merge(options) : options
  end

  def sanitize_sort(allowed_columns, default: 'updated_at')
    sort_param = params[:sort].presence || default
    sql = allowed_columns[sort_param] || allowed_columns[default] || default
    Arel.sql(sql)
  end
end
