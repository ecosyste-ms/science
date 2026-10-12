class Paper < ApplicationRecord
  has_many :mentions, dependent: :destroy
  has_many :projects, through: :mentions
  has_many :project_papers, dependent: :delete_all
  has_many :linked_projects, through: :project_papers, source: :project
  has_many :paper_authors, dependent: :delete_all
  has_many :package_papers, dependent: :delete_all

  def linked_packages
    Package.where(id: package_papers.select(:package_id))
  end

  def self.resolve_openalex_id!(value)
    match = value.to_s.strip.match(%r{\A(?:https?://openalex\.org/)?(W\d+)\z}i)
    raise ArgumentError, "Invalid OpenAlex Work ID: #{value.inspect}" unless match

    id = match[1].downcase
    papers = where("lower(openalex_id) IN (?)", [id, "https://openalex.org/#{id}"])
      .limit(2).to_a
    raise ArgumentError, "Expected one existing paper for #{id.upcase}, found #{papers.size}" unless papers.one?

    papers.first
  end

  def to_s
    title.presence || doi.presence || "Untitled paper"
  end
end
