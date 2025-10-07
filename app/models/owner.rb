class Owner < ApplicationRecord
  belongs_to :host
  has_many :projects, foreign_key: 'owner_id'

  counter_culture :host, column_name: :owners_count

  validates :login, presence: true
  validates :login, uniqueness: { scope: :host_id, case_sensitive: false }
  validates :uuid, uniqueness: { scope: :host_id }, allow_nil: true
end
