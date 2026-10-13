require "delegate"
require "uri"

class FilteredHttpLogger < SimpleDelegator
  def initialize(logger, filters:)
    super(logger)
    @parameter_filter = ActiveSupport::ParameterFilter.new(filters)
  end

  %i[debug info warn error fatal unknown].each do |level|
    define_method(level) do |message = nil, &block|
      if block
        __getobj__.public_send(level) { filter(block.call) }
      else
        __getobj__.public_send(level, filter(message))
      end
    end
  end

  def filter(message)
    message.to_s.gsub(/([?&])([^=&\s]+)=([^&\s#]*)/) do
      prefix, key, value = Regexp.last_match.captures
      decoded_key = URI.decode_www_form_component(key)
      "#{prefix}#{key}=#{@parameter_filter.filter_param(decoded_key, value)}"
    end
  rescue ArgumentError
    "[FILTERED HTTP LOG]"
  end
end
