class Owner < ApplicationRecord
  belongs_to :host
  has_many :projects, foreign_key: 'owner_id'

  validates :login, presence: true
  validates :login, uniqueness: { scope: :host_id, case_sensitive: false }
  validates :uuid, uniqueness: { scope: :host_id }, allow_nil: true
end
