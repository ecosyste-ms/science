class JevQuestions
  STRICT = {
    "type" => "noul", "instructions" => "Does the supplied evidence establish that this project provides software for conducting scientific research?",
    "criteria" => { "true" => "Implements scientific methods, simulations, measurement, domain-specific data analysis, or a tool specifically designed for research workflows. Research-specific infrastructure counts. Publication metadata is not required.",
      "false" => "Generic dependencies or infrastructure merely usable by researchers; tutorials, coursework, resource lists; unrelated applications; or insufficient evidence of a research purpose." }
  }.freeze
  IMPLEMENTATION = {
    "type" => "noul", "instructions" => "Does this repository itself provide executable software implementing scientific methods or a tool specifically designed for conducting scientific research?",
    "criteria" => { "true" => "The repository itself implements scientific computation, simulation, measurement, domain-specific analysis, or research-specific workflow operations. Research-specific infrastructure and bindings count when their research function is established.",
      "false" => "Scientific subject matter alone; descriptions of research; catalogues linking to software elsewhere; papers, datasets or generated outputs without an implementation; teaching examples; generic templates; or general-purpose dependencies and infrastructure. Insufficient evidence of an implementation also counts as false." }
  }.freeze

  def self.for(stage)
    stage == "screen" ? { "strict" => STRICT } : { "implementation" => IMPLEMENTATION }
  end

  def self.versions(stage)
    self.for(stage).transform_values { |question| Digest::SHA256.hexdigest(JSON.generate(question)) }
  end
end
