class QueryBatch
  MAX_ARGUMENTS = 100

  def self.each(rows, arguments_per_row: nil, fixed_arguments: 0, &block)
    return enum_for(__method__, rows,
      arguments_per_row: arguments_per_row,
      fixed_arguments: fixed_arguments) unless block
    return if rows.empty?

    arguments_per_row ||= rows.first.respond_to?(:length) ? rows.first.length : 1
    available_arguments = MAX_ARGUMENTS - fixed_arguments
    if arguments_per_row <= 0 || available_arguments < arguments_per_row
      raise ArgumentError, "query row exceeds the argument limit"
    end

    rows.each_slice(available_arguments / arguments_per_row, &block)
  end
end
