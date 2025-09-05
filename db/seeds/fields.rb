# Seed data for scientific fields
# Based on OpenAlex domains and fields with keywords for classification

Field.find_or_create_by(name: 'Physics') do |f|
  f.domain = 'physical_sciences'
  f.keywords = [
    'quantum', 'particle', 'mechanics', 'optics', 'thermodynamics',
    'relativity', 'electromagnetic', 'nuclear', 'atomic', 'photonics',
    'condensed matter', 'plasma', 'acoustics', 'magnetism', 'laser',
    'cosmology', 'astrophysics', 'gravitational', 'hadron', 'bosons'
  ]
  f.packages = ['qiskit', 'pennylane', 'qutip', 'kwant', 'pyscf']
  f.indicators = ['simulation', 'monte carlo', 'lattice', 'hamiltonian', 'wavefunction']
end

Field.find_or_create_by(name: 'Chemistry') do |f|
  f.domain = 'physical_sciences'
  f.keywords = [
    'molecular', 'reaction', 'synthesis', 'catalyst', 'spectroscopy',
    'crystallography', 'polymer', 'organic', 'inorganic', 'chemical',
    'compound', 'element', 'periodic', 'bond', 'stoichiometry',
    'electrochemistry', 'thermochemistry', 'kinetics', 'equilibrium'
  ]
  f.packages = ['rdkit', 'pymol', 'ase', 'cclib', 'openbabel', 'chempy']
  f.indicators = ['mol', 'compound', 'bond', 'ligand', 'substrate']
end

Field.find_or_create_by(name: 'Earth and Environmental Sciences') do |f|
  f.domain = 'physical_sciences'
  f.keywords = [
    'climate', 'weather', 'ocean', 'atmosphere', 'geology',
    'seismic', 'hydrology', 'meteorology', 'geophysics', 'environmental',
    'earthquake', 'volcano', 'tsunami', 'precipitation', 'temperature',
    'greenhouse', 'carbon', 'ecosystem', 'biodiversity', 'conservation'
  ]
  f.packages = ['xarray', 'cartopy', 'iris', 'netcdf4', 'climlab', 'metpy']
  f.indicators = ['model', 'forecast', 'satellite', 'gis', 'remote sensing']
end

Field.find_or_create_by(name: 'Materials Science') do |f|
  f.domain = 'physical_sciences'
  f.keywords = [
    'materials', 'nanomaterials', 'composite', 'alloy', 'ceramic',
    'semiconductor', 'superconductor', 'metamaterial', 'crystal',
    'diffraction', 'microscopy', 'mechanical properties', 'tensile',
    'hardness', 'corrosion', 'fatigue', 'fracture', 'surface'
  ]
  f.packages = ['pymatgen', 'atomsk', 'ase', 'jarvis', 'aflow']
  f.indicators = ['structure', 'lattice', 'defect', 'grain', 'phase']
end

Field.find_or_create_by(name: 'Biology') do |f|
  f.domain = 'life_sciences'
  f.keywords = [
    'cell', 'organism', 'species', 'ecology', 'evolution',
    'taxonomy', 'biodiversity', 'population', 'phylogenetic', 'biological',
    'ecosystem', 'habitat', 'flora', 'fauna', 'microbe',
    'bacteria', 'virus', 'fungi', 'plant', 'animal'
  ]
  f.packages = ['biopython', 'scikit-bio', 'ete3', 'dendropy', 'ecopy']
  f.indicators = ['sequence', 'tree', 'diversity', 'abundance', 'richness']
end

Field.find_or_create_by(name: 'Medicine') do |f|
  f.domain = 'life_sciences'
  f.keywords = [
    'clinical', 'disease', 'patient', 'treatment', 'diagnosis',
    'epidemiology', 'drug', 'therapy', 'health', 'medical',
    'surgery', 'cancer', 'diabetes', 'cardiovascular', 'infectious',
    'vaccine', 'antibiotic', 'symptom', 'prognosis', 'biomarker'
  ]
  f.packages = ['lifelines', 'nilearn', 'mne', 'dipy', 'nipype']
  f.indicators = ['cohort', 'trial', 'outcome', 'survival', 'risk']
end

Field.find_or_create_by(name: 'Biochemistry, Genetics and Molecular Biology') do |f|
  f.domain = 'life_sciences'
  f.keywords = [
    'protein', 'gene', 'genome', 'dna', 'rna', 'sequencing',
    'expression', 'mutation', 'pathway', 'metabolic', 'enzyme',
    'transcription', 'translation', 'chromosome', 'allele',
    'crispr', 'pcr', 'cloning', 'vector', 'promoter'
  ]
  f.packages = ['scanpy', 'seurat', 'deseq2', 'gatk', 'bioconductor', 'edger']
  f.indicators = ['omics', 'alignment', 'variant', 'snp', 'indel']
end

Field.find_or_create_by(name: 'Agricultural and Biological Sciences') do |f|
  f.domain = 'life_sciences'
  f.keywords = [
    'agriculture', 'crop', 'soil', 'farming', 'livestock',
    'yield', 'irrigation', 'fertilizer', 'pesticide', 'harvest',
    'food', 'nutrition', 'aquaculture', 'forestry', 'horticulture',
    'agronomy', 'breeding', 'cultivar', 'sustainable', 'organic'
  ]
  f.packages = ['cropmodels', 'apsim', 'dssat', 'aquacrop']
  f.indicators = ['production', 'yield', 'growth', 'season', 'cultivar']
end

Field.find_or_create_by(name: 'Neuroscience') do |f|
  f.domain = 'life_sciences'
  f.keywords = [
    'brain', 'neuron', 'synapse', 'neurotransmitter', 'cognition',
    'memory', 'learning', 'neuroimaging', 'fmri', 'eeg',
    'neural', 'cortex', 'hippocampus', 'dopamine', 'serotonin',
    'neurological', 'neurodegenerative', 'alzheimer', 'parkinson'
  ]
  f.packages = ['mne', 'nilearn', 'nipype', 'pysurfer', 'dipy']
  f.indicators = ['connectivity', 'activation', 'signal', 'stimulus', 'response']
end

Field.find_or_create_by(name: 'Psychology') do |f|
  f.domain = 'social_sciences'
  f.keywords = [
    'behavior', 'cognitive', 'perception', 'emotion', 'personality',
    'motivation', 'consciousness', 'mental', 'therapy', 'counseling',
    'developmental', 'social psychology', 'clinical psychology',
    'anxiety', 'depression', 'stress', 'trauma', 'psychometric'
  ]
  f.packages = ['psychopy', 'opensesame', 'expyriment']
  f.indicators = ['questionnaire', 'scale', 'assessment', 'intervention', 'validity']
end

Field.find_or_create_by(name: 'Economics') do |f|
  f.domain = 'social_sciences'
  f.keywords = [
    'economic', 'market', 'finance', 'trade', 'investment',
    'gdp', 'inflation', 'unemployment', 'monetary', 'fiscal',
    'microeconomics', 'macroeconomics', 'econometric', 'equilibrium',
    'supply', 'demand', 'utility', 'game theory', 'behavioral economics'
  ]
  f.packages = ['statsmodels', 'linearmodels', 'quantecon', 'pandas-datareader']
  f.indicators = ['regression', 'elasticity', 'coefficient', 'forecast', 'optimization']
end

Field.find_or_create_by(name: 'Sociology') do |f|
  f.domain = 'social_sciences'
  f.keywords = [
    'society', 'social', 'culture', 'community', 'demographic',
    'inequality', 'gender', 'race', 'class', 'ethnicity',
    'migration', 'urbanization', 'globalization', 'social network',
    'institution', 'norm', 'identity', 'socialization', 'stratification'
  ]
  f.packages = ['networkx', 'igraph', 'snap-stanford']
  f.indicators = ['survey', 'interview', 'ethnography', 'network', 'correlation']
end

Field.find_or_create_by(name: 'Political Science') do |f|
  f.domain = 'social_sciences'
  f.keywords = [
    'politics', 'government', 'democracy', 'election', 'voting',
    'policy', 'governance', 'state', 'power', 'ideology',
    'diplomacy', 'international relations', 'conflict', 'war',
    'parliament', 'congress', 'constitution', 'law', 'justice'
  ]
  f.packages = ['geopandas', 'folium']
  f.indicators = ['poll', 'constituency', 'campaign', 'legislation', 'treaty']
end

Field.find_or_create_by(name: 'Computer Science') do |f|
  f.domain = 'computer_science'
  f.keywords = [
    'algorithm', 'software', 'database', 'network', 'security',
    'compiler', 'operating system', 'distributed', 'parallel',
    'programming', 'data structure', 'complexity', 'computation',
    'architecture', 'cloud', 'api', 'framework', 'debugging'
  ]
  f.packages = ['flask', 'django', 'fastapi', 'redis', 'postgresql']
  f.indicators = ['performance', 'optimization', 'scalability', 'latency', 'throughput']
end

Field.find_or_create_by(name: 'Mathematics') do |f|
  f.domain = 'computer_science'
  f.keywords = [
    'theorem', 'proof', 'algebra', 'calculus', 'statistics',
    'probability', 'topology', 'numerical', 'differential',
    'linear algebra', 'matrix', 'vector', 'eigenvalue', 'integral',
    'derivative', 'limit', 'function', 'equation', 'optimization'
  ]
  f.packages = ['sympy', 'sage', 'statsmodels', 'cvxpy', 'scipy']
  f.indicators = ['equation', 'matrix', 'solver', 'convergence', 'proof']
end

Field.find_or_create_by(name: 'Engineering') do |f|
  f.domain = 'computer_science'
  f.keywords = [
    'control', 'signal', 'robotics', 'mechanical', 'electrical',
    'structural', 'fluid', 'dynamics', 'design', 'system',
    'circuit', 'sensor', 'actuator', 'feedback', 'pid',
    'finite element', 'cad', 'simulation', 'manufacturing'
  ]
  f.packages = ['fenics', 'openfoam', 'ros', 'simpy', 'control']
  f.indicators = ['simulation', 'design', 'system', 'model', 'analysis']
end

Field.find_or_create_by(name: 'Artificial Intelligence and Machine Learning') do |f|
  f.domain = 'computer_science'
  f.keywords = [
    'machine learning', 'deep learning', 'neural network', 'artificial intelligence',
    'classification', 'regression', 'clustering', 'supervised', 'unsupervised',
    'reinforcement learning', 'transformer', 'cnn', 'rnn', 'lstm',
    'gan', 'autoencoder', 'bert', 'gpt', 'computer vision', 'nlp'
  ]
  f.packages = ['tensorflow', 'pytorch', 'scikit-learn', 'keras', 'transformers', 'opencv']
  f.indicators = ['training', 'accuracy', 'loss', 'epoch', 'dataset']
end

puts "Seeded #{Field.count} fields"