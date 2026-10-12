class Paper < ApplicationRecord
  has_many :mentions, dependent: :destroy
  has_many :projects, through: :mentions
  has_many :project_papers, dependent: :delete_all
  has_many :linked_projects, through: :project_papers, source: :project
  has_many :paper_authors, dependent: :delete_all

  def to_s
    title.presence || doi.presence || "Untitled paper"
  end
end
