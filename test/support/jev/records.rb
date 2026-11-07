module Jev::Records
  def discovery_run(**attributes)
    Jev::Run.start!(name: "Discovery #{SecureRandom.hex(8)}", target: 100, seed: "repeatable-sample").tap do |run|
      run.update!(sampling_complete: true, **attributes)
    end
  end

  def discovery_candidate(**attributes)
    url = attributes.fetch(:repository_url) { "https://github.com/discovery/solver-#{SecureRandom.hex(8)}" }
    metadata = { "repository" => url, "description" => "Finite element simulation of soil water" }
    run = attributes.delete(:run) || discovery_run
    Jev::Discovery.create!({ run: run, repository_url: url, source: "repos",
      sampling_method: "seeded_random_page_time_window", sample_group: "external_repositories",
      evidence: { "metadata" => metadata }, evidence_fingerprint: Jev::Evidence.fingerprint(metadata) }.merge(attributes))
  end
end
