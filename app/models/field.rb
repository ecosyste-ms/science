class Field < ApplicationRecord
  has_many :project_fields, dependent: :destroy
  has_many :projects, through: :project_fields
  
  validates :name, presence: true, uniqueness: true
  validates :domain, presence: true
  
  scope :by_domain, ->(domain) { where(domain: domain) }
  
  DOMAINS = {
    'physical_sciences' => 'Physical Sciences',
    'life_sciences' => 'Life Sciences', 
    'social_sciences' => 'Social Sciences',
    'computer_science' => 'Computer Science'
  }
  
  def domain_display_name
    DOMAINS[domain] || domain.humanize
  end
end