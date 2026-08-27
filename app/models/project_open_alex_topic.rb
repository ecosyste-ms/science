class ProjectOpenAlexTopic < ApplicationRecord
  belongs_to :project
  belongs_to :open_alex_topic

  validates :score,
    presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :source, :source_identifier, :openalex_work_id, presence: true
  validates :open_alex_topic_id,
    uniqueness: { scope: %i[project_id source source_identifier] }

  scope :primary, -> { where(primary_topic: true) }
  scope :by_score, -> { order(score: :desc) }
end
