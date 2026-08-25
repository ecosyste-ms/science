class JossVocabularyModel < ApplicationRecord
  validates :term_weights, presence: true
  validates :config, presence: true
  validates :source_counts, presence: true

  def self.latest
    order(created_at: :desc).first
  end
end
