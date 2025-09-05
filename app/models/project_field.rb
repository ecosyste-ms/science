class ProjectField < ApplicationRecord
  belongs_to :project
  belongs_to :field
  
  validates :confidence_score, presence: true, 
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :project_id, uniqueness: { scope: :field_id }
  
  scope :high_confidence, -> { where('confidence_score > ?', 0.7) }
  scope :medium_confidence, -> { where(confidence_score: 0.5..0.7) }
  scope :low_confidence, -> { where(confidence_score: 0.3..0.5) }
  scope :primary, -> { order(confidence_score: :desc).limit(1) }
  scope :by_confidence, -> { order(confidence_score: :desc) }
end