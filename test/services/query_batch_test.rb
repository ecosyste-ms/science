require "test_helper"

class QueryBatchTest < ActiveSupport::TestCase
  test "limits each batch to one hundred arguments" do
    rows = 25.times.map { |index| [index, index, index, index, index] }

    batches = QueryBatch.each(rows).to_a

    assert_equal [20, 5], batches.map(&:length)
  end

  test "reserves arguments used outside repeated rows" do
    rows = 200.times.to_a

    batches = QueryBatch.each(
      rows,
      arguments_per_row: 1,
      fixed_arguments: 4
    ).to_a

    assert_equal [96, 96, 8], batches.map(&:length)
  end
end
