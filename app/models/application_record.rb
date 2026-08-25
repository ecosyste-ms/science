class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_save :strip_null_bytes

  NULL_BYTE = 0.chr.freeze

  def strip_null_bytes
    changed_attributes.each_key do |attr|
      value = self[attr]
      self[attr] = self.class.strip_null_bytes_from(value) if self.class.contains_null_byte?(value)
    end
  end

  def self.contains_null_byte?(value)
    case value
    when String then value.include?(NULL_BYTE)
    when Array then value.any? { |v| contains_null_byte?(v) }
    when Hash then value.any? { |k, v| contains_null_byte?(k) || contains_null_byte?(v) }
    else false
    end
  end

  def self.strip_null_bytes_from(value)
    case value
    when String then value.delete(NULL_BYTE)
    when Array then value.map { |v| strip_null_bytes_from(v) }
    when Hash then value.to_h { |k, v| [strip_null_bytes_from(k), strip_null_bytes_from(v)] }
    else value
    end
  end
end
