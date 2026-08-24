class ScienceScoreCalculator
  attr_reader :project, :breakdown

  ACADEMIC_DOMAIN_SUFFIXES = %w[
    edu ac.uk edu.au edu.cn edu.br edu.mx edu.ar edu.co edu.in ac.jp ac.za
    edu.sg edu.hk edu.my edu.ph edu.tw edu.eg edu.pk edu.vn edu.tr ac.at
    ac.il ac.in ac.nz ac.kr ac.be
    umontpellier.fr sorbonne-universite.fr cnrs.fr inria.fr inserm.fr
    pasteur.fr polytechnique.fr polytechnique.edu centralesupelec.fr ens.fr
    ens-lyon.fr
    mpg.de fraunhofer.de helmholtz.de dlr.de fz-juelich.de tum.de
    rwth-aachen.de dfki.de
    tudelft.nl uva.nl vu.nl rug.nl tue.nl leidenuniv.nl
    ethz.ch epfl.ch cern.ch unige.ch unibas.ch psi.ch
    tuwien.ac.at uibk.ac.at
    huji.ac.il weizmann.ac.il technion.ac.il
    iitb.ac.in iiitd.ac.in iitk.ac.in iisc.ac.in
    embl.de embl.org ebi.ac.uk ku.dk dtu.dk kth.se chalmers.se
    ntnu.no uio.no ucl.ac.uk cam.ac.uk ox.ac.uk ic.ac.uk
    utoronto.ca ubc.ca mcgill.ca uwaterloo.ca ualberta.ca
    csiro.au unsw.edu.au anu.edu.au unimelb.edu.au
    nih.gov nasa.gov noaa.gov usgs.gov nist.gov
    ornl.gov lbl.gov anl.gov bnl.gov fnal.gov
    lanl.gov llnl.gov pnnl.gov inl.gov sandia.gov nrel.gov slac.stanford.edu
    ligo.org ieee.org
  ].freeze

  ACADEMIC_LABEL_PREFIXES = %w[univ- u- uni- tu- fh-].freeze

  ACADEMIC_LABEL_WORDS = %w[university college institute academia].freeze

  ACADEMIC_DOMAINS = (ACADEMIC_DOMAIN_SUFFIXES + ACADEMIC_LABEL_PREFIXES + ACADEMIC_LABEL_WORDS).freeze

  def self.academic_domain?(domain)
    return false unless domain.present?
    domain = domain.downcase
    return true if ACADEMIC_DOMAIN_SUFFIXES.any? { |s| domain == s || domain.end_with?(".#{s}") }
    labels = domain.split('.')
    return true if ACADEMIC_LABEL_PREFIXES.any? { |p| labels.any? { |l| l.start_with?(p) } }
    ACADEMIC_LABEL_WORDS.any? { |w| labels.include?(w) }
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
    deps = project.dependency_packages
    return { present: false, description: "Scientific dependencies", details: nil } if deps.blank?

    matches = deps.select do |ecosystem, name|
      list = SCIENTIFIC_DEPENDENCIES[ecosystem.to_s.downcase]
      list && list.include?(name.to_s.downcase)
    end

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
    strong: %w[Snakemake Nextflow nf-core nf-test MultiQC Dockstore],
    high: ['Quarto', 'R Markdown', 'knitr', 'DVC', 'targets', 'ASV', 'Fortitude'],
    moderate: %w[Jupyter MyST-Parser BenchmarkTools.jl Documenter.jl roxygen2 pkgdown covr testthat renv],
  }.freeze

  def check_research_tooling
    return { present: false, description: "Research tooling", details: nil } unless project.brief.present?

    tools = (project.brief['tools'] || {}).values.flatten
    domains = tools.flat_map { |t| t.dig('taxonomy', 'domain') || [] }.uniq
    if (domains & RESEARCH_DOMAINS).any?
      return {
        present: true,
        strength: 1.0,
        description: "Research tooling",
        details: "Tools tagged domain: #{(domains & RESEARCH_DOMAINS).join(', ')}",
      }
    end

    names = tools.map { |t| t['name'] }.compact
    tier, matches = RESEARCH_TOOLS.lazy.map { |k, v| [k, names & v] }.find { |_, m| m.any? }
    strength = { strong: 1.0, high: 0.7, moderate: 0.4 }[tier]

    {
      present: matches.present?,
      strength: strength,
      description: "Research tooling",
      details: matches.present? ? "Detected: #{matches.join(', ')}" : nil,
    }
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
      
      if self.class.academic_domain?(email_domain)
        academic_committers << {
          name: committer['name'],
          domain: email_domain,
          commits: committer['count']
        }
      end
    end

    fraction = total_committers > 0 ? academic_committers.length.to_f / total_committers : 0.0
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
    owner_json = project.read_attribute(:owner)

    # Check if owner is an organization
    return { present: false, description: "Institutional organization owner", details: nil } unless owner.kind == 'organization'

    # Check if owner has a website
    return { present: false, description: "Institutional organization owner", details: nil } unless owner_json && owner_json['website'].present?

    website = owner_json['website'].downcase

    # Extract domain from website URL
    domain = begin
      uri = URI.parse(website.start_with?('http') ? website : "https://#{website}")
      uri.host
    rescue
      website.gsub(/^(https?:\/\/)?(www\.)?/, '').split('/').first
    end

    return { present: false, description: "Institutional organization owner", details: nil } unless domain

    is_institutional = self.class.academic_domain?(domain)

    {
      present: is_institutional,
      description: "Institutional organization owner",
      details: is_institutional ? "Organization #{owner.login} has institutional domain (#{domain})" : nil
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
    # Calculate similarity score using JOSS IDF
    similarity_score = begin
      # Try to use cached full corpus, otherwise use limited sample
      # This prevents multiple workers from trying to build full corpus simultaneously
      if File.exist?(JossIdfAnalyzer::IDF_CACHE_FILE)
        # Full corpus cache exists, use it
        JossIdfAnalyzer.calculate_joss_idf
      else
        # No cache yet, use limited sample to avoid timeout in Sidekiq
        JossIdfAnalyzer.calculate_joss_idf(limit: 500)
      end
      project.joss_idf_score
    rescue => e
      Rails.logger.error "Error calculating JOSS vocabulary similarity: #{e.message}"
      0.0
    end
    
    # Consider moderate similarity (>30%) as present for non-JOSS projects
    threshold = 30.0
    has_similarity = similarity_score >= threshold
    
    {
      present: has_similarity,
      description: "Scientific vocabulary similarity",
      details: if similarity_score > 0
        has_similarity ? 
          "#{similarity_score.round(1)}% similarity to JOSS scientific vocabulary" : 
          "Low similarity (#{similarity_score.round(1)}%) to scientific vocabulary"
      else
        "Unable to calculate vocabulary similarity"
      end,
      score: similarity_score
    }
  end
end