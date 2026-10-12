namespace :papers do
  desc "Review citation identities against OpenAlex without importing (FILE=input.json OUTPUT=report.json)"
  task resolve_candidates: :environment do
    input = ENV.fetch("FILE")
    output = ENV.fetch("OUTPUT")
    raise ArgumentError, "Input and output must be different files" if File.expand_path(input) == File.expand_path(output)
    data = JSON.parse(File.read(input))
    candidates = data.is_a?(Hash) ? data.fetch("candidates") : data
    report = PaperIdentityResolver.new.call(candidates)
    File.write(output, JSON.pretty_generate(report) + "\n")
    puts "Paper identity review: #{report.fetch('summary').inspect}"
  end

  desc "Import reviewed package-paper relationships from JSON (FILE=path; purl, openalex_id, role, evidence)"
  task import_package_pairs: :environment do
    rows = JSON.parse(File.read(ENV.fetch("FILE")))
    puts "Package-paper relationships: #{PackagePaper.import_verified!(rows).inspect}"
  end

  desc "Import verified project-paper pairs from JSON (FILE=path; repository_url, openalex_id, evidence with source and url)"
  task import_project_pairs: :environment do
    rows = JSON.parse(File.read(ENV.fetch("FILE")))
    puts "Project-paper pairs: #{ProjectPaper.import_verified!(rows).inspect}"
  end

  desc "export papers to markdown"
  task :export => :environment do
    markdown_string = ""

    categories = {}

    Project.with_works.group_by(&:category).each do |category, cat_projects|
      categories[category] = []
      markdown_string << "## #{category}\n\n"
      
      cat_projects.group_by(&:sub_category).each do |sub_category, projects|
        markdown_string << "### #{sub_category}\n\n"

        categories[category] << sub_category

        projects.each do |project|

          project.works.each do |doi, work|
            next if work.nil?
            
            markdown_string << "- [#{work['title']}](https://doi.org/#{doi})\n"
            
          end
        end
      end
    end

    # table of contents
    toc = "## Contents\n\n"
    categories.each do |category, sub_categories|
      toc << "- [#{category}](##{category.downcase.gsub(' ', '-')})\n"
      sub_categories.each do |sub_category|
        toc << "  - [#{sub_category}](##{sub_category.downcase.gsub(' ', '-')})\n"
      end
    end
    toc << "\n"

    markdown_string = "# Open Sustainable Papers\n\n" + toc + markdown_string
    
    puts markdown_string
  end
end
