class CitationContentClassifier
  Result = Struct.new(:format, :cff, :error, keyword_init: true) do
    def cff?
      format == :cff
    end

    def bibtex?
      format == :bibtex
    end

    def unstructured?
      format == :unstructured
    end

    def invalid?
      format == :invalid
    end
  end

  ClassificationError = Class.new(StandardError)
  BIBTEX_ENTRY_PATTERN = /(?:\A|[\r\n])[\t ]*@\w+[\t ]*([{(])/i
  CFF_FILE_NAME_PATTERN = /[.]cff\z/i
  CFF_LIKE_KEY_PATTERN = /(?:\A|[\r\n])[\t ]*(?:authors|cff-version|message|preferred-citation|title)[\t ]*:/i
  CFF_LIKE_KEYS = %w[authors cff-version message preferred-citation title].freeze
  DELIMITER_PAIRS = {
    "{" => "}",
    "(" => ")",
  }.freeze

  attr_reader :content, :file_name

  def self.classify(content, file_name: nil)
    new(content, file_name: file_name).classify
  end

  def initialize(content, file_name: nil)
    @content = content.to_s
    @file_name = file_name.to_s
  end

  def classify
    return result(:unstructured) if content.blank?

    bibtex_match = content.match(BIBTEX_ENTRY_PATTERN)
    return classify_bibtex(bibtex_match) if bibtex_match

    parsed = YAML.safe_load(
      content,
      aliases: true,
      permitted_classes: [Date, Time]
    )
    return classify_cff(parsed) if cff_mapping?(parsed)

    result(:unstructured)
  rescue Psych::Exception => error
    cff_like_content? ? result(:invalid, error: error) : result(:unstructured)
  end

  def classify_bibtex(match)
    return result(:bibtex) if complete_bibtex_entry?(match)

    result(
      :invalid,
      error: ClassificationError.new("BibTeX entry is incomplete")
    )
  end

  def classify_cff(parsed)
    cff = CFF::Index.new(parsed)
    cff.validate!
    result(:cff, cff: cff)
  rescue StandardError => error
    result(:invalid, error: error)
  end

  def cff_mapping?(parsed)
    return false unless parsed.is_a?(Hash)
    return true if file_name.match?(CFF_FILE_NAME_PATTERN)

    keys = parsed.keys.map(&:to_s)
    keys.include?("cff-version") ||
      (keys & CFF_LIKE_KEYS).length >= 2
  end

  def cff_like_content?
    content.match?(CFF_LIKE_KEY_PATTERN)
  end

  def complete_bibtex_entry?(match)
    stack = []
    quoted = false
    escaped = false
    comment = false

    content[match.end(0) - 1..].each_char do |character|
      if comment
        comment = false if character == "\n" || character == "\r"
        next
      end
      if escaped
        escaped = false
        next
      end
      if character == "\\"
        escaped = true
        next
      end
      if character == '"'
        quoted = !quoted
        next
      end
      next if quoted
      if character == "%"
        comment = true
      elsif DELIMITER_PAIRS.key?(character)
        stack << DELIMITER_PAIRS.fetch(character)
      elsif DELIMITER_PAIRS.value?(character)
        return false unless stack.last == character

        stack.pop
        return true if stack.empty?
      end
    end

    false
  end

  def result(format, cff: nil, error: nil)
    Result.new(format: format, cff: cff, error: error).freeze
  end
end
