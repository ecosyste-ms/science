class JevRequest < ApplicationRecord
  belongs_to :jev_run
  validates :digest, presence: true
end
