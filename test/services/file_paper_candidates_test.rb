require "test_helper"

class FilePaperCandidatesTest < ActiveSupport::TestCase
  test "publisher DOI paths survive text BibTeX and CFF extraction" do
    url = "https://publisher.example/article/10.1234%2FExample?download=true#citation"
    files = {
      "README.md" => "[Paper](#{url}).",
      "CITATION.bib" => "@article{example, title={An example}, url={#{url}}}",
      "CITATION.cff" => "cff-version: 1.2.0\npreferred-citation:\n  type: article\n  title: An example\n  url: #{url}\n",
    }
    files.each do |path, content|
      candidates = FilePaperCandidates.new("path" => path, "content" => content).extract
      assert_equal [["doi", "10.1234/example"]], candidates.map { |item| item.values_at("identifier_kind", "identifier") }
      assert candidates.sole.fetch("occurrences").all? { |item| item.fetch("raw").include?(url) }
    end
  end

  test "publisher DOI extraction ignores query parameters and preserves balanced suffix parentheses" do
    content = "https://publisher.example/article/10.1234/ABC(2020)?tracking=1.\nhttps://publisher.example/?next=10.1234/not-a-path\nhttps://publisher.example/article/10.123/not-a-doi\nhttps://publisher.example/paper.pdf\n"
    candidates = FilePaperCandidates.new("path" => "README.md", "content" => content).extract
    assert_equal [["doi", "10.1234/abc(2020)"], ["paper_url", "https://publisher.example/paper.pdf"]],
      candidates.map { |item| item.values_at("identifier_kind", "identifier") }
  end
end
