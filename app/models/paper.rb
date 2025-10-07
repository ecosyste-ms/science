class Paper < ApplicationRecord
  has_many :mentions, dependent: :destroy
  has_many :projects, through: :mentions
end
