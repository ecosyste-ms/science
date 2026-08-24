require 'faraday'
require 'json'

module ScienceScoreAnalysis
  API = 'https://science.ecosyste.ms/api/v1'

  module_function

  def compare
    ids = {}
    (api_get('/projects?per_page=40&sort=science_score&order=desc') || []).each { |p| ids[p['id']] = 'high' }
    (api_get('/projects?per_page=40&sort=science_score&order=asc') || []).each { |p| ids[p['id']] ||= 'low' }
    (api_get('/projects?per_page=40&sort=last_synced_at&order=desc') || []).each { |p| ids[p['id']] ||= 'recent' }
    puts "Sample: #{ids.length} projects (#{ids.values.tally})"
    puts

    puts format('%-6s %-60s  cit cod zen doi com own reg  score', 'bucket', 'url')
    puts '-' * 118

    rows = []
    ids.each do |id, bucket|
      data = api_get("/projects/#{id}")
      next unless data
      project = build_project_from_api(data)
      calc = ScienceScoreCalculator.new(project)
      breakdown = {
        has_citation_file: calc.check_citation_file,
        has_codemeta: calc.check_codemeta_file,
        has_zenodo: calc.check_zenodo_file,
        has_doi_in_readme: calc.check_doi_in_readme,
        has_academic_links: { present: false },
        has_academic_committers: calc.check_academic_committers,
        has_institutional_owner: calc.check_institutional_owner,
        has_scientific_registry: calc.check_scientific_registry,
        has_joss_paper: calc.check_joss_paper,
        joss_vocabulary_similarity: { present: false },
      }
      calc.instance_variable_set(:@breakdown, breakdown)
      score = calc.calculate_score[:score]
      rows << [bucket, data['url'], score]
      puts format('%-6s %-60s  %-3s %-3s %-3s %-3s %-3s %-3s %-3s  %5.1f',
                  bucket, data['url'][0, 60],
                  flag(breakdown[:has_citation_file]),
                  flag(breakdown[:has_codemeta]),
                  flag(breakdown[:has_zenodo]),
                  flag(breakdown[:has_doi_in_readme]),
                  flag(breakdown[:has_academic_committers]),
                  flag(breakdown[:has_institutional_owner]),
                  flag(breakdown[:has_scientific_registry]),
                  score)
    end

    puts
    puts "score excludes academic_links and joss_vocabulary (readme not in API)"
    puts
    %w[high low recent].each do |bucket|
      scores = rows.select { |b, *| b == bucket }.map(&:last)
      next if scores.empty?
      puts format('%-6s  n=%d  min=%.1f  median=%.1f  max=%.1f',
                  bucket, scores.length, scores.min, scores.sort[scores.length / 2], scores.max)
    end
  end

  def joss_signals(sample: 200)
    puts "Fetching #{sample} JOSS URLs..."
    joss_urls = fetch_joss_urls(sample)

    puts "Fetching #{sample} non-JOSS projects..."
    nonjoss = fetch_non_joss(sample)

    puts "Looking up JOSS projects in science API..."
    joss_features = joss_urls.map { |u| $stderr.print '.'; extract_features(find_by_url(u)) }.reject(&:empty?)
    $stderr.puts
    nonjoss_features = nonjoss.map { |p| extract_features(p) }

    puts
    puts "n(joss)=#{joss_features.length}  n(nonjoss)=#{nonjoss_features.length}"
    puts
    puts format('%-28s %8s %8s %8s', 'signal', 'joss %', 'nonjoss', 'ratio')
    puts '-' * 56
    %i[has_citation has_codemeta has_zenodo has_journal_doi has_archive_doi
       has_academic_committer has_packages owner_academic].each do |k|
      j = pct(joss_features) { |f| f[k] }
      n = pct(nonjoss_features) { |f| f[k] }
      ratio = n > 0 ? (j / n).round(1) : (j > 0 ? '∞' : '-')
      puts format('%-28s %8.1f %8.1f %8s', k, j, n, ratio)
    end

    puts
    ja = joss_features.map { |f| f[:academic_committer_frac] }.compact
    na = nonjoss_features.map { |f| f[:academic_committer_frac] }.compact
    puts format('%-28s %8s %8s', 'academic_committer_frac avg',
                ja.any? ? (ja.sum / ja.length).round(2) : '-',
                na.any? ? (na.sum / na.length).round(2) : '-')

    puts
    puts "owner_kind distribution:"
    [[joss_features, 'joss'], [nonjoss_features, 'nonjoss']].each do |arr, label|
      puts "  #{label}: #{arr.map { |f| f[:owner_kind] }.tally}"
    end

    print_top_comparison('ecosystems', joss_features, nonjoss_features, :ecosystems)
    print_language_comparison(joss_features, nonjoss_features)
    print_top_comparison('direct dependencies more common in JOSS', joss_features, nonjoss_features, :deps, min: 5, limit: 30)
    print_top_comparison('topics more common in JOSS', joss_features, nonjoss_features, :topics, min: 3, limit: 30)
  end

  def fetch_joss_urls(n)
    urls = []
    page = 1
    while urls.length < n
      papers = get_json("https://joss.theoj.org/papers/published.json?page=#{page}")
      break if papers.nil? || papers.empty?
      urls.concat(papers.map { |p| p['software_repository'] }.compact.map { |u| u.downcase.chomp('/') })
      page += 1
    end
    urls.uniq.first(n)
  end

  def fetch_non_joss(n)
    data = []
    page = 1
    while data.length < n
      batch = api_get("/projects?per_page=100&page=#{page}&sort=last_synced_at&order=desc") || []
      break if batch.empty?
      batch.reject! { |p| (p['readme_doi_urls'] || []).any? { |d| d.include?('10.21105') } }
      data.concat(batch)
      page += 1
    end
    data.first(n)
  end

  def api_get(path)
    get_json("#{API}#{path}")
  end

  def find_by_url(url)
    results = api_get("/projects/search?q=#{CGI.escape(url)}&per_page=10") || []
    results.find { |p| p['url'] == url }
  end

  def get_json(url)
    resp = Faraday.get(url, nil, { 'User-Agent' => 'science.ecosyste.ms/analysis' })
    resp.success? ? JSON.parse(resp.body) : nil
  rescue
    nil
  end

  def build_project_from_api(data)
    p = Project.new(
      url: data['url'],
      repository: data['repository'],
      packages: data['packages'],
      commits: data['commits'],
      citation_file: data.dig('repository', 'metadata', 'files', 'citation') ? 'present' : nil,
      joss_metadata: (data['readme_doi_urls'] || []).any? { |d| d.include?('10.21105') } ? { 'doi' => 'joss' } : nil
    )
    p.define_singleton_method(:owner_record) do
      return nil unless data['owner'] && data['owner']['login']
      OpenStruct.new(kind: data['owner']['kind'], login: data['owner']['login'])
    end
    p.define_singleton_method(:read_attribute) { |attr| attr == :owner ? data['owner'] : super(attr) }
    p.readme = (data['readme_doi_urls'] || []).join(' ') if data['readme_doi_urls'].present?
    p
  end

  def extract_features(p)
    return {} if p.nil?
    files = p.dig('repository', 'metadata', 'files') || {}
    committers = p.dig('commits', 'committers') || []
    academic = committers.count { |c| c['email'] && ScienceScoreCalculator.academic_domain?(c['email'].split('@').last) }
    packages = p['packages'] || []
    ecosystems = packages.map { |pkg| pkg['ecosystem'] }.compact.map(&:downcase).uniq
    dois = (p['readme_doi_urls'] || []).map { |d| d[%r{10\.\d{4,}/[-._;()/:\w]+}] }.compact.uniq
    archive_dois = dois.select { |d| d.start_with?('10.5281', '10.6084') }
    journal_dois = dois - archive_dois - dois.select { |d| d.start_with?('10.21105') }
    deps = (p['dependencies'] || []).flat_map { |m| (m['dependencies'] || []).select { |d| d['direct'] }.map { |d| "#{d['ecosystem']}:#{d['package_name']&.downcase}" } }
    {
      has_citation: files['citation'].present?,
      has_codemeta: files['codemeta'].present?,
      has_zenodo: files['zenodo'].present?,
      has_journal_doi: journal_dois.any?,
      has_archive_doi: archive_dois.any?,
      has_academic_committer: academic > 0,
      academic_committer_frac: committers.any? ? (academic.to_f / committers.length).round(2) : nil,
      has_packages: packages.any?,
      ecosystems: ecosystems,
      owner_kind: p.dig('owner', 'kind'),
      owner_academic: ScienceScoreCalculator.academic_domain?(p.dig('owner', 'website').to_s.sub(%r{^https?://(www\.)?}, '').split('/').first),
      language: p.dig('repository', 'language'),
      topics: (p.dig('repository', 'topics') || []).map(&:downcase),
      deps: deps.uniq,
    }
  end

  def flag(check)
    return '.' unless check[:present]
    s = check[:strength]
    s.nil? ? 'X' : format('%.1f', s).sub(/^0/, '')
  end

  def pct(arr, &blk)
    return 0.0 if arr.empty?
    (arr.count(&blk).to_f / arr.length * 100).round(1)
  end

  def tally_key(arr, key, n = 20)
    arr.flat_map { |f| f[key] || [] }.tally.sort_by { |_, c| -c }.first(n)
  end

  def print_top_comparison(label, joss, nonjoss, key, min: 1, limit: 20)
    puts
    puts "top #{label}:"
    n_tally = tally_key(nonjoss, key, 500).to_h
    tally_key(joss, key, 200).map { |k, jc| [k, jc, n_tally[k] || 0] }
      .select { |_, jc, _| jc >= min }
      .sort_by { |_, jc, nc| -(jc - nc) }
      .first(limit)
      .each { |k, jc, nc| puts format('  %-40s joss=%3d  nonjoss=%3d', k, jc, nc) }
  end

  def print_language_comparison(joss, nonjoss)
    puts
    puts "top languages:"
    nl = nonjoss.map { |f| f[:language] }.compact.tally
    joss.map { |f| f[:language] }.compact.tally.sort_by { |_, c| -c }.first(15)
      .each { |lang, c| puts format('  %-20s joss=%3d  nonjoss=%3d', lang, c, nl[lang] || 0) }
  end
end
