class SoftwareIdentifier
  SCHEMES = %w[rrid wikidata biotools ascl swmath doi].freeze

  def self.normalize(value, scheme)
    value = value.strip
    case scheme
    when "rrid" then RridClient.identifier(value)
    when "biotools" then BiotoolsClient.identifier(value)
    when "ascl" then AsclClient.identifier(value)
    when "swmath" then SwmathClient.identifier(value)
    when "doi" then SoftwareDoiClient.identifier(value)
    when "wikidata"
      WikidataClient.validate_ids!([value.upcase])
      value.upcase
    else
      raise ArgumentError, "unsupported identifier scheme"
    end
  end
end
