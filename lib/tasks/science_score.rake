require 'faraday'
require 'json'

namespace :science_score do
  SCIENCE_API = 'https://science.ecosyste.ms/api/v1' unless defined?(SCIENCE_API)

  desc 'Compare local ScienceScoreCalculator against a stratified sample from the prod API'
  task compare: :environment do
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

  desc 'Compare attribute prevalence in JOSS vs non-JOSS projects (SAMPLE=200)'
  task joss_signals: :environment do
    sample = (ENV['SAMPLE'] || 200).to_i

    puts "Fetching #{sample} JOSS URLs..."
    joss_urls = []
    page = 1
    while joss_urls.length < sample
      papers = get_json("https://joss.theoj.org/papers/published.json?page=#{page}")
      break if papers.nil? || papers.empty?
      joss_urls.concat(papers.map { |p| p['software_repository'] }.compact.map { |u| u.downcase.chomp('/') })
      page += 1
    end
    joss_urls = joss_urls.uniq.first(sample)

    puts "Fetching #{sample} non-JOSS projects..."
    nonjoss = []
    page = 1
    while nonjoss.length < sample
      batch = api_get("/projects?per_page=100&page=#{page}&sort=last_synced_at&order=desc") || []
      break if batch.empty?
      batch.reject! { |p| (p['readme_doi_urls'] || []).any? { |d| d.include?('10.21105') } }
      nonjoss.concat(batch)
      page += 1
    end
    nonjoss = nonjoss.first(sample)

    puts "Looking up JOSS projects in science API..."
    joss_features = joss_urls.map { |u| $stderr.print '.'; extract_features(api_get("/projects/lookup?url=#{CGI.escape(u)}")) }.reject(&:empty?)
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

    puts
    puts "top ecosystems (joss / nonjoss):"
    ne = tally_key(nonjoss_features, :ecosystems).to_h
    tally_key(joss_features, :ecosystems).each { |eco, c| puts format('  %-20s joss=%3d  nonjoss=%3d', eco, c, ne[eco] || 0) }

    puts
    puts "top languages:"
    nl = nonjoss_features.map { |f| f[:language] }.compact.tally
    joss_features.map { |f| f[:language] }.compact.tally.sort_by { |_, c| -c }.first(15)
      .each { |lang, c| puts format('  %-20s joss=%3d  nonjoss=%3d', lang, c, nl[lang] || 0) }

    puts
    puts "top 30 direct dependencies more common in JOSS:"
    nd = tally_key(nonjoss_features, :deps, 500).to_h
    tally_key(joss_features, :deps, 200).map { |dep, jc| [dep, jc, nd[dep] || 0] }
      .select { |_, jc, _| jc >= 5 }
      .sort_by { |_, jc, nc| -(jc - nc) }
      .first(30)
      .each { |dep, jc, nc| puts format('  %-40s joss=%3d  nonjoss=%3d', dep, jc, nc) }

    puts
    puts "top 30 topics more common in JOSS:"
    nt = tally_key(nonjoss_features, :topics, 500).to_h
    tally_key(joss_features, :topics, 200).map { |t, jc| [t, jc, nt[t] || 0] }
      .select { |_, jc, _| jc >= 3 }
      .sort_by { |_, jc, nc| -(jc - nc) }
      .first(30)
      .each { |t, jc, nc| puts format('  %-40s joss=%3d  nonjoss=%3d', t, jc, nc) }
  end

  def api_get(path)
    get_json("#{SCIENCE_API}#{path}")
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
end
