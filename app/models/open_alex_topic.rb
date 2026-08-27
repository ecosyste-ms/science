class OpenAlexTopic < ApplicationRecord
  has_many :project_open_alex_topics, dependent: :delete_all
  has_many :projects, through: :project_open_alex_topics

  validates :openalex_id, presence: true, uniqueness: true
  validates :display_name, :subfield_id, :subfield_name,
    :field_id, :field_name, :domain_id, :domain_name, presence: true

  scope :active, -> { where(active: true) }
end
