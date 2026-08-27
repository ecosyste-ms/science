ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require 'webmock/minitest'
require 'mocha/minitest'

require 'sidekiq_unique_jobs/testing'
Sidekiq.testing!(:fake)

class ActiveSupport::TestCase
  # Make sure Shoulda Matchers are configured correctly
  Shoulda::Matchers.configure do |config|
    config.integrate do |with|
      with.test_framework :minitest
      with.library :rails
    end
  end

  # If you need transactional fixtures (common for DB tests, less so for controller tests)
  # self.use_transactional_fixtures = true

  # If you need instatiated fixtures
  # fixtures :all

  # Add more helper methods to be used by all tests here...
  def create_research_organization_domain(
    domain,
    source: "manual",
    version: "test",
    external_id: domain,
    organization_name: nil,
    organization_types: [],
    strength: 1.0,
    active: true
  )
    ResearchOrganizationDomain.create!(
      domain: domain,
      source: source,
      source_version: version,
      external_id: external_id,
      organization_name: organization_name,
      organization_types: organization_types,
      strength: strength,
      active: active
    )
  end
end

# Ensure WebMock blocks external connections by default, allowing localhost if needed (e.g., Capybara)
WebMock.disable_net_connect!(allow_localhost: true)
