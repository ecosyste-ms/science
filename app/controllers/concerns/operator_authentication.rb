module OperatorAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_operator
    protect_from_forgery with: :exception
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
