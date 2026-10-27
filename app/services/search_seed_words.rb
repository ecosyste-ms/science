require "digest"

class SearchSeedWords
  attr_reader :sources

  def initialize
    reviewed_path = Rails.root.join("config/search_seed_common_words.txt")
    @reviewed = File.read(reviewed_path).split.to_set
    directory = Rails.root.join("config/search_seed_dictionary")
    source = JSON.parse(File.read(directory.join("source.json")))
    dictionary_path = directory.join(source.fetch("file"))
    raise "Dictionary checksum differs from source metadata" unless Digest::SHA256.file(dictionary_path).hexdigest == source.fetch("sha256")

    @dictionary = File.readlines(dictionary_path, chomp: true).to_set
    source["copyright_notice"] = File.read(directory.join(source.fetch("copyright")))
    @sources = [
      { "id" => "reviewed", "kind" => "reviewed_list", "language" => "en",
        "file" => "config/search_seed_common_words.txt", "sha256" => Digest::SHA256.file(reviewed_path).hexdigest },
      source,
    ]
  end

  def evidence(value)
    matches = []
    matches << { source: "reviewed", kind: "reviewed_list", language: "en" } if @reviewed.include?(value)
    matches << { source: "esdb", kind: "dictionary", language: "en" } if @dictionary.include?(value)
    matches
  end
end
