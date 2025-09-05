FactoryBot.define do
  factory :field do
    sequence(:name) { |n| "Field #{n}" }
    domain { Field::DOMAINS.keys.sample }
    keywords { ['keyword1', 'keyword2', 'keyword3'] }
    packages { ['package1', 'package2'] }
    indicators { ['indicator1', 'indicator2'] }
    
    trait :physics do
      name { 'Physics' }
      domain { 'physical_sciences' }
      keywords { ['quantum', 'mechanics', 'particles', 'energy', 'matter'] }
      packages { ['numpy', 'scipy', 'matplotlib'] }
      indicators { ['simulation', 'experiment', 'theory'] }
    end
    
    trait :biology do
      name { 'Biology' }
      domain { 'life_sciences' }
      keywords { ['genetics', 'cell', 'dna', 'organism', 'evolution'] }
      packages { ['biopython', 'bioconductor', 'blast'] }
      indicators { ['organism', 'species', 'genome'] }
    end
    
    trait :computer_science do
      name { 'Computer Science' }
      domain { 'computer_science' }
      keywords { ['algorithm', 'data', 'software', 'computation', 'programming'] }
      packages { ['tensorflow', 'pytorch', 'scikit-learn'] }
      indicators { ['computation', 'performance', 'algorithm'] }
    end
    
    trait :chemistry do
      name { 'Chemistry' }
      domain { 'physical_sciences' }
      keywords { ['molecules', 'reactions', 'atoms', 'compounds'] }
      packages { ['rdkit', 'openbabel', 'chempy'] }
      indicators { ['reaction', 'synthesis', 'molecular'] }
    end
  end
end