require "test_helper"

class CitationContentClassifierTest < ActiveSupport::TestCase
  test "classifies and validates CFF with a YAML preamble" do
    result = classify(<<~CFF, file_name: "docs/CITATION.CFF")
      # Generated citation metadata
      ---
      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: Ada
          family-names: Lovelace
    CFF

    assert result.cff?
    assert_equal "Example Software", result.cff.title
    assert_nil result.error
  end

  test "rejects CFF that fails schema validation" do
    result = classify(<<~CFF, file_name: "CITATION.cff")
      Please cite this release:

      cff-version: 1.2.0
      message: Cite this software
      title: Example Software
      authors:
        - given-names: Ada
          family-names: Lovelace
    CFF

    assert result.invalid?
    assert_instance_of CFF::ValidationError, result.error
  end

  test "rejects malformed CFF YAML" do
    result = classify(
      "cff-version: 1.2.0\ntitle: [\n",
      file_name: "CITATION.cff"
    )

    assert result.invalid?
    assert_instance_of Psych::SyntaxError, result.error
  end

  test "classifies a complete BibTeX entry after citation instructions" do
    result = classify(<<~BIBTEX, file_name: "CITATION.cff")
      Please cite this software using:

      @software{example,
        author = {Lovelace, Ada},
        title = {Example {Software}}
      }
    BIBTEX

    assert result.bibtex?
    assert_nil result.error
  end

  test "rejects an incomplete BibTeX entry" do
    result = classify(
      "@software{example,\n  title = {Example}\n",
      file_name: "CITATION.bib"
    )

    assert result.invalid?
    assert_instance_of CitationContentClassifier::ClassificationError,
      result.error
  end

  test "classifies plain citation instructions as unstructured" do
    result = classify(
      "Please cite Doe et al. (2026), Example Software.",
      file_name: "CITATION.cff"
    )

    assert result.unstructured?
    assert_nil result.error
  end

  test "classifies generic YAML front matter as unstructured" do
    result = classify("---\ntitle: Documentation\n---\n", file_name: "CITATION.md")

    assert result.unstructured?
    assert_nil result.error
  end

  def classify(content, file_name: nil)
    CitationContentClassifier.classify(content, file_name: file_name)
  end
end
