FactoryBot.define do
  factory :project_field do
    project
    field
    confidence_score { rand(0.3..0.95) }
    match_signals do
      {
        'keywords' => rand(0.2..0.9),
        'readme' => rand(0.1..0.8),
        'packages' => rand(0.0..0.7),
        'indicators' => rand(0.0..0.5)
      }
    end
    
    trait :high_confidence do
      confidence_score { rand(0.7..0.95) }
    end
    
    trait :medium_confidence do
      confidence_score { rand(0.5..0.69) }
    end
    
    trait :low_confidence do
      confidence_score { rand(0.3..0.49) }
    end
    
    trait :no_signals do
      match_signals { nil }
    end
  end
end