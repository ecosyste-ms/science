require "test_helper"

class FieldTest < ActiveSupport::TestCase
  test "uses the field name as its URL slug" do
    field = Field.create!(
      name: "Computer Science",
      domain: "Physical Sciences",
      openalex_id: "https://openalex.org/fields/17"
    )

    assert_equal "computer-science", field.to_param
    assert_equal "Physical Sciences", field.domain_display_name
    assert_includes Field.open_alex, field
  end
end
