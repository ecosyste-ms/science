class RPackageDescription
  FIELDS = %w[Package Title Description URL BugReports].freeze

  def self.fields(content)
    fields = Hash.new { |hash, key| hash[key] = [] }
    current = nil
    content.each_line do |line|
      break if line.strip.empty?

      if (match = line.match(/\A([A-Za-z][A-Za-z0-9@-]*):[\t ]*(.*)/))
        current = FIELDS.include?(match[1]) ? match[1] : nil
        fields[current] << match[2].strip if current
      elsif current && line.match?(/\A[\t ]/)
        fields[current][-1] += " #{line.strip}"
      else
        current = nil
      end
    end
    fields.filter_map do |key, values|
      [key, values.sole] if values.one? && values.sole.present?
    end.to_h
  end

  def self.urls(value)
    value.to_s.scan(%r{https?://[^\s,<>]+}i).filter_map do |url|
      url = url.sub(/[);.]+\z/, "")
      uri = URI.parse(url)
      url if uri.host.present?
    rescue URI::InvalidURIError
      nil
    end.uniq
  end
end
