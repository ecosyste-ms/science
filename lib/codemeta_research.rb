module CodemetaResearch
  module_function

  def normalize_version(version_string)
    return nil if version_string.blank?
    version_string.to_s.strip.downcase.sub(/\Av(?:ersion[-_\s]*)?/, '')
  end

  def clone_and_analyze(project, base_dir: nil)
    return [] unless project.repository.present?

    clone_url = project.repository['clone_url'] || "#{project.url}.git"
    repo_name = project.url.split('/').last(2).join('_')

    base_dir ||= Dir.mktmpdir('codemeta_research')
    repo_path = File.join(base_dir, repo_name)

    results = []

    begin
      unless Dir.exist?(repo_path)
        puts "Cloning #{project.url}..."
        system("git clone --quiet #{clone_url} #{repo_path}")
        unless $?.success?
          return [{ error: "Failed to clone repository", release_tag: nil }]
        end
      end

      tags = []
      Dir.chdir(repo_path) do
        system("git fetch --tags --quiet 2>/dev/null")
        tag_output = `git tag --sort=creatordate`
        tags = tag_output.split("\n").map(&:strip).reject(&:empty?)
      end

      if tags.empty?
        return [{ error: "No tags found in repository", release_tag: nil }]
      end

      puts "  Found #{tags.count} tags"

      tags.each do |tag|
        puts "  Checking tag #{tag}..."

        result = {
          project_id: project.id,
          project_url: project.url,
          release_tag: tag,
          release_date: nil,
          codemeta_exists: false,
          codemeta_version: nil,
          version_matches_tag: nil,
          codemeta_file_path: nil,
          error: nil
        }

        begin
          Dir.chdir(repo_path) do
            tag_date = `git log -1 --format=%aI #{tag} 2>/dev/null`.strip
            result[:release_date] = Time.parse(tag_date) if tag_date.present?
          rescue ArgumentError
          end

          Dir.chdir(repo_path) do
            system("git checkout --quiet #{tag} 2>/dev/null")
            unless $?.success?
              result[:error] = "Failed to checkout tag"
              results << result
              next
            end

            codemeta_paths = ['codemeta.json', '.codemeta.json']
            codemeta_paths.each do |path|
              if File.exist?(path)
                result[:codemeta_exists] = true
                result[:codemeta_file_path] = path

                begin
                  data = JSON.parse(File.read(path))
                  codemeta_version = data['version'] || data['softwareVersion']

                  if codemeta_version.present?
                    result[:codemeta_version] = codemeta_version
                    normalized_codemeta = normalize_version(codemeta_version)
                    normalized_tag = normalize_version(tag)
                    result[:version_matches_tag] = (normalized_codemeta == normalized_tag)
                  end
                rescue JSON::ParserError => e
                  result[:error] = "JSON parse error: #{e.message}"
                end

                break
              end
            end
          end
        rescue => e
          result[:error] = e.message
        end

        results << result
      end

    rescue => e
      results << { error: "Repository clone error: #{e.message}", release_tag: nil }
    end

    results
  end

  def analyze_history(project, base_dir: nil)
    return [] unless project.repository.present?

    clone_url = project.repository['clone_url'] || "#{project.url}.git"
    repo_name = project.url.split('/').last(2).join('_')

    base_dir ||= Dir.mktmpdir('codemeta_research')
    repo_path = File.join(base_dir, repo_name)

    results = []

    begin
      unless Dir.exist?(repo_path)
        puts "Cloning #{project.url}..."
        system("git clone --quiet #{clone_url} #{repo_path}")
        unless $?.success?
          return [{ error: "Failed to clone repository" }]
        end
      end

      codemeta_paths = ['codemeta.json', '.codemeta.json']

      Dir.chdir(repo_path) do
        system("git fetch --quiet 2>/dev/null")

        codemeta_paths.each do |file_path|
          next unless system("git cat-file -e HEAD:#{file_path} 2>/dev/null")

          puts "  Analyzing history of #{file_path}..."

          log_output = `git log --follow --format="%H|%aI|%an|%ae|%s" -- #{file_path}`

          log_output.split("\n").each do |line|
            parts = line.split("|", 5)
            next if parts.length < 5

            commit_hash = parts[0]
            commit_date = parts[1]
            author_name = parts[2]
            author_email = parts[3]
            commit_message = parts[4]

            file_content = `git show #{commit_hash}:#{file_path} 2>/dev/null`

            codemeta_version = nil
            parse_error = nil

            if file_content.present?
              begin
                codemeta_data = JSON.parse(file_content)
                codemeta_version = codemeta_data['version'] || codemeta_data['softwareVersion']
              rescue JSON::ParserError => e
                parse_error = e.message
              end
            end

            results << {
              project_id: project.id,
              project_url: project.url,
              file_path: file_path,
              commit_hash: commit_hash,
              commit_date: Time.parse(commit_date),
              author_name: author_name,
              author_email: author_email,
              commit_message: commit_message,
              codemeta_version: codemeta_version,
              parse_error: parse_error
            }
          end

          break if results.any?
        end
      end

      if results.empty?
        results << { error: "No codemeta file found in repository history" }
      end

    rescue => e
      results << { error: "Repository analysis error: #{e.message}" }
    end

    results
  end
end
