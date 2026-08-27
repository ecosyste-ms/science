require "test_helper"

class RailsComponentsTest < ActiveSupport::TestCase
  test "unused Rails components are not loaded" do
    loaded_railties = Rails.application.railties.map { |railtie| railtie.class.name }

    assert_not_includes loaded_railties, "ActiveJob::Railtie"
    assert_not_includes loaded_railties, "ActionMailer::Railtie"
    assert_not_includes loaded_railties, "ActiveStorage::Engine"
    assert_not_includes loaded_railties, "ActionCable::Engine"
    assert_not_includes loaded_railties, "ActionMailbox::Engine"
    assert_not_includes loaded_railties, "ActionText::Engine"
  end
end
