class ScienceScoreCalculator
  attr_reader :project, :breakdown

  RESEARCH_TOOLING_BONUS = 0.20
  SCIENTIFIC_DEPENDENCY_BONUS = 0.08

  def self.academic_domain?(domain)
    ResearchOrganizationDomainMatcher.institutional?(domain)
  end

  DOI_PATTERNS = [
    %r{10\.\d{4,}/[-._;()/:\w]+},
    %r{doi\.org/10\.\d{4,}},
    %r{dx\.doi\.org/10\.\d{4,}}
  ]

  ACADEMIC_LINK_PATTERNS = [
    %r{arxiv\.org},
    %r{biorxiv\.org}, 
    %r{medrxiv\.org},
    %r{preprints\.org},
    %r{researchgate\.net},
    %r{academia\.edu},
    %r{scholar\.google},
    %r{pubmed\.ncbi},
    %r{ncbi\.nlm\.nih\.gov},
    %r{sciencedirect\.com},
    %r{springer\.com},
    %r{wiley\.com},
    %r{nature\.com},
    %r{science\.org},
    %r{plos\.org},
    %r{frontiersin\.org},
    %r{mdpi\.com},
    %r{ieee\.org},
    %r{acm\.org},
    %r{aps\.org},
    %r{iop\.org},
    %r{rsc\.org},
    %r{acs\.org},
    %r{joss\.theoj\.org},
    %r{zenodo\.org}
  ]

  def initialize(project)
    @project = project
    @breakdown = {}
  end

  def calculate
    @breakdown = {
      has_citation_file: check_citation_file,
      has_codemeta: check_codemeta_file,
      has_zenodo: check_zenodo_file,
      has_doi_in_readme: check_doi_in_readme,
      has_academic_links: check_academic_links,
      has_academic_committers: check_academic_committers,
      has_institutional_owner: check_institutional_owner,
      has_scientific_registry: check_scientific_registry,
      has_scientific_dependencies: check_scientific_dependencies,
      has_research_tooling: check_research_tooling,
      negative_indicators: check_negative_indicators,
      has_joss_paper: check_joss_paper
    }

    unless project.joss_metadata.present?
      @breakdown[:joss_vocabulary_similarity] = check_joss_vocabulary_similarity
    end

    calculate_score
  end

  def calculate_score
    # JOSS projects are automatically scientific (peer-reviewed)
    if project.joss_metadata.present?
      # JOSS projects get base 85% plus any additional indicators
      base_score = 85.0
      bonus_weight = 0.0
      
      # Add bonuses for additional scientific indicators (up to 15%)
      bonus_weights = {
        has_citation_file: 0.05,
        has_codemeta: 0.03,
        has_zenodo: 0.03,
        has_doi_in_readme: 0.02,
        has_academic_committers: 0.02,
        has_institutional_owner: 0.03
      }
      
      @breakdown.each do |key, value|
        if value[:present] && bonus_weights[key]
          bonus_weight += bonus_weights[key]
        end
      end
      
      final_score = base_score + (bonus_weight * 100)
    else
      weighted_score = 0.0

      scoring_weights = {
        has_citation_file: 0.16,
        has_codemeta: 0.13,
        has_zenodo: 0.15,
        has_doi_in_readme: 0.13,
        has_academic_links: 0.08,
        has_academic_committers: 0.05,
        has_institutional_owner: 0.10,
        has_scientific_registry: 0.07,
        has_scientific_dependencies: 0.0,
        has_research_tooling: 0.0,
        joss_vocabulary_similarity: 0.13
      }

      @breakdown.each do |key, value|
        next if key == :has_joss_paper || key == :negative_indicators
        next unless value[:present]
        weight = scoring_weights[key] || 0
        weighted_score += weight * (value[:strength] || 1.0)
      end

      final_score = (weighted_score / scoring_weights.values.sum) * 100

      research_tooling = @breakdown[:has_research_tooling]
      if research_tooling[:present]
        strength = research_tooling[:strength] || 1.0
        vocabulary_present = @breakdown.dig(:joss_vocabulary_similarity, :present)
        bonus_applies = strength > 0.4 || vocabulary_present
        bonus = bonus_applies ? RESEARCH_TOOLING_BONUS * strength * 100 : 0.0
        research_tooling[:score] = bonus.round(2)
        final_score += bonus
      end

      scientific_dependencies = @breakdown[:has_scientific_dependencies]
      if scientific_dependencies[:present]
        bonus_applies = scientific_dependencies[:strength] == 1.0
        bonus = bonus_applies ? SCIENTIFIC_DEPENDENCY_BONUS * 100 : 0.0
        scientific_dependencies[:score] = bonus.round(2)
        final_score += bonus
      end

      penalty = @breakdown.dig(:negative_indicators, :penalty) || 0.0
      final_score *= (1.0 - penalty)
    end
    
    {
      score: [final_score.round(2), 100.0].min,
      breakdown: @breakdown,
      max_score: 100
    }
  end

  def check_citation_file
    {
      present: project.citation_file.present?,
      description: "CITATION.cff file",
      details: project.citation_file.present? ? "Found CITATION.cff file" : nil
    }
  end

  def check_codemeta_file
    has_codemeta = false

    if project.repository.present? &&
       project.repository['metadata'].present? &&
       project.repository['metadata']['files'].present?

      files = project.repository['metadata']['files']
      has_codemeta = files.any? { |k, v| k.to_s.downcase.include?('codemeta') && v.present? }
    end

    {
      present: has_codemeta,
      description: "codemeta.json file",
      details: has_codemeta ? "Found codemeta.json file" : nil
    }
  end

  def check_zenodo_file
    has_zenodo = false

    if project.repository.present? &&
       project.repository['metadata'].present? &&
       project.repository['metadata']['files'].present?

      files = project.repository['metadata']['files']
      has_zenodo = files.any? { |k, v| k.to_s.downcase.include?('zenodo') && v.present? }
    end

    {
      present: has_zenodo,
      description: ".zenodo.json file",
      details: has_zenodo ? "Found .zenodo.json file" : nil
    }
  end

  ARCHIVE_DOI_PREFIXES = %w[10.5281 10.6084].freeze

  def check_doi_in_readme
    dois = []

    if project.readme.present?
      readme_text = project.readme.downcase
      DOI_PATTERNS.each do |pattern|
        dois.concat(readme_text.scan(pattern))
      end
    end

    if project.joss_metadata.present? && project.joss_metadata['doi']
      dois << project.joss_metadata['doi']
    end

    dois = dois.map { |d| d[%r{10\.\d{4,}/[-._;()/:\w]+}] }.compact.uniq
    archive_dois, journal_dois = dois.partition do |d|
      ARCHIVE_DOI_PREFIXES.any? { |prefix| d.include?(prefix) }
    end

    details = if dois.any?
      parts = []
      parts << "#{journal_dois.length} journal" if journal_dois.any?
      parts << "#{archive_dois.length} archive" if archive_dois.any?
      "Found #{dois.length} DOI reference(s) (#{parts.join(', ')})"
    end

    {
      present: dois.any?,
      description: "DOI references",
      details: details,
      journal_dois: journal_dois.length,
      archive_dois: archive_dois.length
    }
  end

  SCIENTIFIC_REGISTRIES = %w[cran bioconductor].freeze

  SCIENTIFIC_DEPENDENCIES = {
    'pypi' => %w[
      scipy astropy biopython rdkit rdkit-pypi xarray mne pysam pymatgen qiskit
      ase nibabel scikit-bio deap iris cf-units obspy sunpy healpy emcee corner
      yt galpy pycbc cobra scanpy anndata mdanalysis openmm nilearn dipy
      scikit-image scikit-allel pyscf gpaw cclib pint uncertainties sympy
      networkx numba h5py netcdf4 zarr dask cartopy shapely geopandas rasterio
      pyproj fiona pyvista vtk mayavi meshio fenics dolfinx firedrake
    ],
    'conda' => %w[
      scipy astropy biopython rdkit xarray mne pysam pymatgen qiskit ase
      nibabel obspy sunpy openmm nilearn scikit-image sympy numba h5py
      netcdf4 zarr dask cartopy geopandas rasterio pyvista vtk fenics
    ],
    'cran' => %w[
      sf terra raster stars ape phytools phangorn vegan ade4 seqinr
      brms rstan rstanarm cmdstanr lavaan lme4 nlme mgcv survival
      spatstat sp rgdal rgeos gstat deSolve
    ],
    'bioconductor' => %w[
      deseq2 edger limma biostrings genomicranges summarizedexperiment
      biocgenerics iranges s4vectors annotationdbi genomicfeatures
      rtracklayer rsamtools variantannotation
    ],
    'julia' => %w[
      differentialequations diffeqbase ordinarydiffeq flux turing jump
      biosequences unitful measurements distributions statsbase
      dataframes plots makie fftw dsp
    ],
    'cargo' => %w[
      ndarray nalgebra bio rust-bio noodles polars
    ],
  }.freeze

  def check_scientific_dependencies
    own = (project.packages || []).map { |pkg| [pkg['ecosystem'], pkg['name']] }
    self_match = own.any? do |ecosystem, name|
      list = SCIENTIFIC_DEPENDENCIES[ecosystem.to_s.downcase]
      list && list.include?(name.to_s.downcase)
    end
    if self_match
      return {
        present: true,
        strength: 1.0,
        description: "Scientific dependencies",
        details: "Package is in the scientific dependency list",
      }
    end

    deps = project.dependency_packages
    return { present: false, description: "Scientific dependencies", details: nil } if deps.blank?

    matches = deps.select do |ecosystem, name|
      list = SCIENTIFIC_DEPENDENCIES[ecosystem.to_s.downcase]
      list && list.include?(name.to_s.downcase)
    end.uniq { |_, name| name.to_s.downcase }

    strength = case matches.length
               when 0 then 0.0
               when 1 then 0.4
               when 2 then 0.7
               else 1.0
               end

    {
      present: matches.any?,
      strength: strength,
      description: "Scientific dependencies",
      details: matches.any? ? "#{matches.length} matched: #{matches.first(5).map { |e, n| "#{e}:#{n}" }.join(', ')}" : nil,
      matches: matches.length,
    }
  end

  RESEARCH_DOMAINS = %w[research bioinformatics scientific-computing high-performance-computing].freeze

  RESEARCH_TOOLS = {
    strong: %w[snakemake nextflow nf-core nf-test multiqc dockstore],
    high: %w[dvc asv fortitude],
    moderate: ['quarto', 'r markdown', 'knitr', 'jupyter', 'myst-parser', 'benchmarktools.jl',
               'documenter.jl', 'roxygen2', 'pkgdown', 'covr', 'testthat', 'renv', 'targets'],
  }.freeze

  R_RESEARCH_TOOLS = %w[pkgdown testthat roxygen2 covr renv targets].freeze
  JULIA_RESEARCH_TOOLS = %w[documenter.jl benchmarktools.jl].freeze
  JULIA_PACKAGE_MANAGERS = %w[pkg].freeze
  PYTHON_MATURITY_CATEGORIES = %w[docs test coverage lint typecheck].freeze
  PYTHON_MATURITY_THRESHOLD = 3

  def check_research_tooling
    return { present: false, description: "Research tooling", details: nil } unless project.brief.present?
    return { present: false, description: "Research tooling", details: "scan error: #{project.brief['error']}" } if project.brief['error']

    tools_by_category = project.brief['tools'].is_a?(Hash) ? project.brief['tools'] : {}
    tools = tools_by_category.values.flatten.select { |tool| tool.is_a?(Hash) }
    names = tools.filter_map { |tool| tool['name']&.downcase }.uniq
    domains = tools.flat_map { |tool| Array(tool.dig('taxonomy', 'domain')) }.map(&:downcase).uniq
    languages = brief_names('languages')
    package_managers = brief_names('package_managers')
    categories = tools_by_category.keys.map(&:downcase)
    evidence = []

    domain_matches = domains & RESEARCH_DOMAINS
    domain_matches.each { |domain| evidence << [1.0, "domain: #{domain}"] }

    (names & RESEARCH_TOOLS[:strong]).each do |name|
      evidence << [1.0, "tool: #{name}"]
    end

    if languages.any? { |language| language.include?('fortran') }
      evidence << [1.0, "language: fortran"]
    end

    r_matches = names & R_RESEARCH_TOOLS
    if languages.include?('r') && r_matches.length >= 2
      evidence << [0.7, "R tooling: #{r_matches.join(', ')}"]
    elsif languages.include?('r') && r_matches.any?
      evidence << [0.4, "R tooling: #{r_matches.join(', ')}"]
    end

    julia_matches = names & JULIA_RESEARCH_TOOLS
    julia_package_matches = package_managers & JULIA_PACKAGE_MANAGERS
    if languages.include?('julia') && julia_matches.any? && julia_package_matches.any?
      matches = julia_matches + julia_package_matches
      evidence << [0.7, "Julia tooling: #{matches.join(', ')}"]
    elsif languages.include?('julia') && julia_package_matches.any?
      evidence << [0.4, "Julia tooling: #{julia_package_matches.join(', ')}"]
    end

    (names & RESEARCH_TOOLS[:high]).each do |name|
      evidence << [0.7, "tool: #{name}"]
    end

    (names & RESEARCH_TOOLS[:moderate]).each do |name|
      evidence << [0.4, "tool: #{name}"]
    end

    maturity_categories = categories & PYTHON_MATURITY_CATEGORIES
    if languages.include?('python') && maturity_categories.length >= PYTHON_MATURITY_THRESHOLD
      evidence << [0.4, "Python maturity: #{maturity_categories.join(', ')}"]
    end

    strength = evidence.map(&:first).max
    strongest_evidence = evidence.select { |value, _| value == strength }.map(&:last).uniq

    {
      present: evidence.any?,
      strength: strength,
      description: "Research tooling",
      details: evidence.any? ? "Detected: #{strongest_evidence.join(', ')}" : nil,
      evidence: evidence.map(&:last).uniq,
    }
  end

  def brief_names(key)
    Array(project.brief[key]).filter_map do |item|
      name = item.is_a?(Hash) ? item['name'] : item
      name.to_s.downcase if name.present?
    end.uniq
  end

  NEGATIVE_TOPICS_STRONG = %w[
    awesome awesome-list dotfiles homework homework-assignments
    interview interview-prep interview-questions interview-preparation
    cheatsheet cheatsheets roadmap
  ].freeze

  NEGATIVE_TOPICS_WEAK = %w[
    tutorial tutorials course courses template templates boilerplate
    starter starter-kit example examples demo learning-exercise
    portfolio personal-website blog
  ].freeze

  def check_negative_indicators
    topics = (project.repository&.dig('topics') || []).map(&:downcase)
    name = (project.repository&.dig('full_name') || project.url).to_s.downcase
    description = project.description.to_s.downcase

    matches = []
    matches.concat((topics & NEGATIVE_TOPICS_STRONG).map { |t| [:strong, "topic:#{t}"] })
    matches.concat((topics & NEGATIVE_TOPICS_WEAK).map { |t| [:weak, "topic:#{t}"] })
    matches << [:strong, 'name:awesome-'] if name.match?(%r{/awesome-})
    matches << [:weak, 'name:-template'] if name.match?(/-template\b/)
    matches << [:weak, 'name:-example'] if name.match?(/-examples?\b/)
    matches << [:weak, 'desc:list-of'] if description.match?(/\b(curated )?list of\b/)
    matches << [:weak, 'fork'] if project.repository&.dig('fork') && !project.repository&.dig('source_name').nil?

    tiers = matches.map(&:first)
    penalty = if tiers.include?(:strong)
      0.8
    elsif tiers.include?(:weak)
      0.5
    else
      0.0
    end

    {
      present: matches.any?,
      penalty: penalty,
      description: "Non-research indicators",
      details: matches.any? ? matches.map(&:last).join(', ') : nil
    }
  end

  def check_scientific_registry
    return { present: false, description: "Scientific package registry", details: nil } unless project.packages.present?

    registries = project.packages.map do |pkg|
      pkg['ecosystem'] || pkg.dig('registry', 'ecosystem') || pkg.dig('registry', 'name')
    end.compact.map(&:downcase).uniq

    matches = registries & SCIENTIFIC_REGISTRIES

    {
      present: matches.any?,
      description: "Scientific package registry",
      details: matches.any? ? "Published on #{matches.join(', ')}" : nil,
      registries: registries
    }
  end

  def check_academic_links
    return { present: false, description: "Academic links in README", details: nil } unless project.readme.present?
    
    readme_text = project.readme.downcase
    academic_sites = []
    
    ACADEMIC_LINK_PATTERNS.each do |pattern|
      if readme_text.match?(pattern)
        site_name = pattern.source.gsub(/\\\./, '.').gsub(/[\\^$]/, '')
        academic_sites << site_name
      end
    end

    {
      present: academic_sites.any?,
      description: "Academic publication links",
      details: academic_sites.any? ? "Links to: #{academic_sites.uniq.join(', ')}" : nil
    }
  end

  def check_academic_committers
    return { present: false, description: "Academic email domains", details: nil } unless project.raw_committers.present?
    
    academic_committers = []
    total_committers = project.raw_committers.length
    
    project.raw_committers.each do |committer|
      next unless committer['email'].present?
      
      email_domain = committer['email'].split('@').last&.downcase
      next unless email_domain
      
      match = ResearchOrganizationDomainMatcher.match(email_domain)
      if match
        academic_committers << {
          name: committer['name'],
          domain: email_domain,
          commits: committer['count'],
          source: match[:source],
          strength: match[:strength],
        }
      end
    end

    matched_strength = academic_committers.sum { |committer| committer.fetch(:strength) }
    fraction = total_committers > 0 ? matched_strength / total_committers : 0.0
    percentage = (fraction * 100).round(1)

    {
      present: academic_committers.any?,
      strength: fraction,
      description: "Committers with academic emails",
      details: academic_committers.any? ?
        "#{academic_committers.length} of #{total_committers} committers (#{percentage}%) from academic institutions" : nil,
      committers: academic_committers.take(5)
    }
  end

  def check_institutional_owner
    return { present: false, description: "Institutional organization owner", details: nil } unless project.owner_record.present?

    owner = project.owner_record
    return { present: false, description: "Institutional organization owner", details: nil } unless owner.kind == 'organization'
    match = owner.institutional_match

    {
      present: match.present?,
      strength: match&.fetch(:strength),
      description: "Institutional organization owner",
      details: match ? "Organization #{owner.login} has institutional domain (#{owner.website_domain} via #{match.fetch(:domain)}, #{match.fetch(:source)})" : nil,
      domain: match&.fetch(:domain),
      source: match&.fetch(:source),
      external_id: match&.fetch(:external_id),
    }
  end

  def check_joss_paper
    {
      present: project.joss_metadata.present?,
      description: "JOSS paper metadata",
      details: project.joss_metadata.present? ? "Published in Journal of Open Source Software" : nil
    }
  end

  def check_joss_vocabulary_similarity
    analysis = project.joss_vocabulary_analysis
    similarity_score = analysis[:score]
    threshold = 30.0
    has_similarity = similarity_score >= threshold

    {
      present: has_similarity,
      description: "Scientific vocabulary similarity",
      details: if analysis[:model_id].nil?
        "Scientific vocabulary model unavailable"
      elsif analysis[:terms].any?
        "Vocabulary score #{similarity_score.round(1)} from #{analysis[:terms].join(', ')}"
      else
        "No scientific vocabulary matches"
      end,
      score: similarity_score,
      terms: analysis[:terms],
      model_id: analysis[:model_id]
    }
  end
end
