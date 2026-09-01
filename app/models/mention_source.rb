class MentionSource < ApplicationRecord
  belongs_to :mention

  validates :source, presence: true
  validates :source_identifier,
    presence: true,
    uniqueness: { scope: :source, case_sensitive: false }
  validates :source_digest, presence: true
end
