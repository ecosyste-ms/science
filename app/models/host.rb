class Host < ApplicationRecord
  has_many :owners
  has_many :projects

  validates :name, presence: true, uniqueness: true
end
