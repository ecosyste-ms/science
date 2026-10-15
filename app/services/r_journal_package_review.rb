require "open3"
require "yaml"

class RJournalPackageReview
  def call(repository:, slugs: nil, limit: 20, after: nil)
    raise ArgumentError, "limit must be between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)
    revision = git(repository, "rev-parse", "refs/remotes/origin/published^{commit}").strip
    candidates = slugs || git(repository, "ls-tree", "--name-only", "#{revision}:_articles").lines.map(&:strip).grep(/\ARJ-\d{4}-\d{3}\z/)
    raise ArgumentError, "invalid article slug" unless candidates.is_a?(Array) && candidates.all? { |slug| slug.match?(/\ARJ-\d{4}-\d{3}\z/) }
    raise ArgumentError, "invalid AFTER slug" if after && !after.match?(/\ARJ-\d{4}-\d{3}\z/)
    candidates = candidates.uniq.sort.reverse
    candidates = candidates.select { |slug| slug < after } if after
    selected = candidates.first(limit)
    records = selected.map do |slug|
      path = "_articles/#{slug}/#{slug}.Rmd"
      content = git(repository, "show", "#{revision}:#{path}")
      review(content, slug).merge("source_path" => path)
    rescue ArgumentError, Psych::Exception => error
      { "slug" => slug, "status" => "unresolved", "reason" => error.message }
    end
    { "revision" => revision, "ref" => "origin/published", "records" => records,
      "next_after" => candidates.size > limit ? selected.last : nil,
      "summary" => { "articles" => records.size, "subject_packages" => records.sum { |row| Array(row["subject_packages"]).size },
        "mentioned_packages" => records.sum { |row| Array(row["mentioned_packages"]).size },
        "unresolved_articles" => records.count { |row| row["status"] == "unresolved" } } }
  end

  def review(content, slug)
    raise ArgumentError, "article exceeds 2 MB" if content.bytesize > 2.megabytes
    frontmatter = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)&.[](1)
    raise ArgumentError, "missing article frontmatter" unless frontmatter
    metadata = YAML.safe_load(frontmatter, permitted_classes: [Date], aliases: false)
    raise ArgumentError, "article slug disagrees with its path" unless metadata.is_a?(Hash) && metadata["slug"] == slug
    raise ArgumentError, "article is a draft" unless metadata["draft"] == false
    date = Date.iso8601(metadata.fetch("date").to_s)
    raise ArgumentError, "article date is in the future" if date > Date.current
    title = metadata.fetch("title")
    raise ArgumentError, "missing article title" unless title.is_a?(String) && title.present?
    packages = metadata["packages"]
    candidates = []
    invalid = []
    if packages.is_a?(Hash)
      { "cran" => "cran", "bioc" => "bioconductor" }.each do |field, ecosystem|
        Array(packages[field]).each do |name|
          if name.is_a?(String) && name.match?(/\A[A-Za-z][A-Za-z0-9.]*\z/)
            candidates << { "ecosystem" => ecosystem, "name" => name }
          else
            invalid << { "ecosystem" => ecosystem, "value" => name, "reason" => "not an unversioned package name" }
          end
        end
      end
    end
    title_text = title.delete("`*")
    prefix = title_text.match(/\A(?:R Package\s+)?([A-Za-z][A-Za-z0-9.]*(?:\s+(?:and|&)\s+[A-Za-z][A-Za-z0-9.]*)*):/i)&.[](1)
    names = prefix ? prefix.split(/\s+(?:and|&)\s+/i).map(&:downcase) : []
    candidates = candidates.uniq { |package| [package.fetch("ecosystem"), package.fetch("name").downcase] }
    subjects, mentioned = candidates.partition { |package| names.include?(package.fetch("name").downcase) }
    { "slug" => slug, "title" => title, "article_url" => "https://journal.r-project.org/articles/#{slug}/",
      "status" => subjects.any? ? "candidate" : "unresolved",
      "reason" => subjects.any? ? "package named in title and publisher registry metadata" : "no agreement between title prefix and registry metadata",
      "subject_packages" => subjects, "mentioned_packages" => mentioned, "invalid_package_entries" => invalid }
  rescue KeyError => error
    raise ArgumentError, "missing article metadata: #{error.key}"
  end

  def git(repository, *arguments)
    output, error, status = Open3.capture3("git", "-C", repository, *arguments)
    raise ArgumentError, "Could not read published article: #{error.strip.truncate(300)}" unless status.success?
    output
  end
end
