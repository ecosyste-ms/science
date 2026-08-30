module Project::Classification
  extend ActiveSupport::Concern

  class_methods do
    def unique_keywords_for_category(category)
      # Get all keywords from all categories
      all_keywords = Project.where.not(category: category).pluck(:keywords).flatten

      # Get keywords from the specific category
      category_keywords = Project.where(category: category).pluck(:keywords).flatten

      # Get keywords that only appear in the specific category
      unique_keywords = category_keywords - all_keywords

      # remove stop words
      unique_keywords = unique_keywords - ignore_words

      # Group the unique keywords by their values and sort them by the size of each group
      sorted_keywords = unique_keywords.group_by { |keyword| keyword }.sort_by { |keyword, occurrences| -occurrences.size }.map(&:first)
      sorted_keywords
    end

    def unique_keywords_for_sub_category(subcategory)
      # Get all keywords from all subcategory
      all_keywords = Project.where.not(sub_category: subcategory).pluck(:keywords).flatten

      # Get keywords from the specific subcategory
      subcategory_keywords = Project.where(sub_category: subcategory).pluck(:keywords).flatten

      # Get keywords that only appear in the specific subcategory
      unique_keywords = subcategory_keywords - all_keywords

      # remove stop words
      unique_keywords = unique_keywords - ignore_words

      # Group the unique keywords by their values and sort them by the size of each group
      sorted_keywords = unique_keywords.group_by { |keyword| keyword }.sort_by { |keyword, occurrences| -occurrences.size }.map(&:first)
      sorted_keywords
    end

    def all_category_keywords
      @all_category_keywords ||= Project.where.not(category: nil).pluck(:category).uniq.map do |category|
        {
          category: category,
          keywords: unique_keywords_for_category(category)
        }
      end
    end

    def all_sub_category_keywords
      @all_sub_category_keywords ||= Project.where.not(sub_category: nil).pluck(:sub_category).uniq.map do |subcategory|
        {
          sub_category: subcategory,
          keywords: unique_keywords_for_sub_category(subcategory)
        }
      end
    end

    def category_tree
      results = visible.group(:category, :sub_category).count

      results.group_by { |(category, _), _| category }.map do |category, rows|
        {
          category: category,
          count: rows.sum { |_, count| count },
          sub_categories: rows.map do |(_, sub_category), count|
            {
              sub_category: sub_category,
              count: count
            }
          end
        }
      end
    end
  end

  def primary_field
    open_alex_fields_with_scores.first&.first
  end

  def all_fields_with_confidence
    open_alex_fields_with_scores
  end

  def open_alex_fields_with_scores
    project_fields.to_a
      .select { |project_field| project_field.field.openalex_id.present? }
      .sort_by do |project_field|
        [-project_field.confidence_score, project_field.field.openalex_id]
      end
      .map { |project_field| [project_field.field, project_field.confidence_score] }
  end

  def contributor_topics(limit: 10, minimum: 3)
    return {} unless commits.present?
    return {} unless commits['committers'].present?
    return {} unless contributors.length > 1

    ignored_keywords = (keywords + Project.ignore_words).uniq

    all_topics = contributors.flat_map { |c| c.topics }.reject{|t| ignored_keywords.include?(t) }
    
    # Group by the stemmed version of the topic
    grouped_topics = all_topics.group_by { |topic| topic.stem }

    # For each group, keep one of the original topics and count the occurrences
    topic_counts = grouped_topics.map do |stemmed_topic, original_topics|
      [original_topics.first, original_topics.size]
    end.to_h

    popular_topics = topic_counts.reject{|t,c| c < minimum }.sort_by { |topic, count| -count }.first(limit).to_h
  end

  def update_keywords_from_contributors
    ct = contributor_topics(limit: 10, minimum: 3)
    update(keywords_from_contributors: ct.keys) if ct.present?
  end

  def suggest_category
    return unless keywords.present?

    cat = Project.all_category_keywords.map do |category|
      {
        category: category[:category],
        score: (keywords & category[:keywords]).length
      }
    end.sort_by{|c| -c[:score] }.first
    return nil if cat[:score] == 0
    cat
  end

  def suggest_sub_category
    return unless keywords.present?

    cat = Project.all_sub_category_keywords.map do |subcategory|
      {
        sub_category: subcategory[:sub_category],
        score: (keywords & subcategory[:keywords]).length
      }
    end.sort_by{|c| -c[:score] }.first
    return nil if cat[:score] == 0
    cat
  end
end
