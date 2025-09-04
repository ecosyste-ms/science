module ApplicationHelper
  include Pagy::Frontend

  def meta_title
    [@meta_title, 'Open Source Science Software'].compact.join(' | ')
  end

  def meta_description
    @meta_description || app_description
  end

  def app_name
    "Open Source Science Software"
  end

  def app_description
    'A discovery and classification system for open source scientific software projects, research tools, and computational libraries across all scientific domains.'
  end

  def obfustcate_email(email)
    return unless email.present?
    
    email.split('@').map do |part|
      if part.length > 2
        part.tap { |p| p[1...-1] = "****" }
      else
        part
      end
    end.join('@')
  end

  def distance_of_time_in_words_if_present(time)
    return 'N/A' unless time
    distance_of_time_in_words(time)
  end

  def rounded_number_with_delimiter(number)
    return 0 unless number
    number_with_delimiter(number.round(2))
  end

  def render_markdown(str)
    return '' unless str.present?
    GitHub::Markup.render('README.md', str)
  end
end
