class Paper < ApplicationRecord
  has_many :mentions, dependent: :destroy
  has_many :projects, through: :mentions
  has_many :paper_authors, dependent: :delete_all

  def to_s
    title.presence || doi.presence || "Untitled paper"
  end
end
