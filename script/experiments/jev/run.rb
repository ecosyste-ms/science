#!/usr/bin/env ruby

require "json"
require "digest"
require "fileutils"
require "optparse"
require "time"
require "faraday"
require "dotenv/load"

module JevExperiment
  API = "https://api.typesafe.ai/v1/systemone"
  PRICE = 0.042
  QUESTIONS = {
    "primary" => { type: "noul", instructions: "Is the primary purpose of this software scientific research?" },
    "workflow" => { type: "noul", instructions: "Is this software specifically designed to perform or support scientific research workflows, such as scientific measurement, simulation, domain-specific analysis, or reproducible research?" },
    "general" => { type: "noul", instructions: "Is this primarily a general-purpose dependency, developer tool, or infrastructure applicable across many non-research uses?" },
    "education" => { type: "noul", instructions: "Is this primarily educational material, a tutorial, coursework, a demonstration, or a list of resources rather than software for conducting research?" },
    "implementation" => { type: "noul", instructions: "Does this repository itself provide executable software implementing scientific methods or a tool specifically designed for conducting scientific research?",
      criteria: { "true" => "The repository itself implements scientific computation, simulation, measurement, domain-specific analysis, or research-specific workflow operations. Research-specific infrastructure and bindings count when their research function is established.",
        "false" => "Scientific subject matter alone; descriptions of research; catalogues linking to software elsewhere; papers, datasets or generated outputs without an implementation; teaching examples; generic templates; or general-purpose dependencies and infrastructure. Insufficient evidence of an implementation also counts as false." } },
    "subject" => { type: "noul", instructions: "Does this project concern scientific research or a scientific subject, regardless of whether it contains research software?" },
    "strict" => { type: "noul", instructions: "Does the supplied evidence establish that this project provides software for conducting scientific research?",
      criteria: { "true" => "Implements scientific methods, simulations, measurement, domain-specific data analysis, or a tool specifically designed for research workflows. Research-specific infrastructure counts. Publication metadata is not required.",
        "false" => "Generic dependencies or infrastructure merely usable by researchers; tutorials, coursework, resource lists; unrelated applications; or insufficient evidence of a research purpose." } },
    "broad" => { type: "noul", instructions: "Could this software be useful to scientists in their research?" },
    "kind" => { type: "choice", instructions: "Which category best describes the primary purpose evidenced by this project?",
      criteria: { "research" => "Software implementing scientific methods or domain-specific scientific analysis, simulation, or measurement",
        "research_workflow" => "Software specifically designed to manage, reproduce, or support scientific research workflows",
        "general" => "General-purpose software, dependencies, developer tools, or infrastructure",
        "education" => "Tutorial, coursework, demonstration, or educational examples",
        "unrelated" => "Non-research application or resource list",
        "insufficient" => "Insufficient information to establish the purpose" } }
  }.freeze
  PILOT_QUESTIONS = QUESTIONS.slice(*%w[primary workflow general education strict broad kind]).freeze

  def self.state(project, variant)
    repo = project["repository"] || {}
    description = project["description"].to_s.strip.empty? ? repo["description"] : project["description"]
    state = { "name" => project["name"], "description" => description }.compact
    return state if variant == "description"

    state["repository"] = project["url"]
    state["topics"] = (Array(project["keywords"]) + Array(repo["topics"])).uniq.first(40)
    state["language"] = project["language"] || repo["language"]
    state["packages"] = Array(project["packages"]).grep(Hash).first(8).map { |p| p.slice("name", "description", "ecosystem") }
    state["package_descriptions"] = Array(repo.dig("metadata", "r_package_descriptions")).grep(Hash).first(3).map { |p| (p["fields"] || {}).slice("Package", "Title", "Description") }
    if variant == "readme" && !project["readme"].to_s.strip.empty?
      state["readme"] = project["readme"].to_s[0, 8000]
    end
    state.reject { |_, value| value.nil? || value == [] }
  end

  def self.get(url)
    response = Faraday.get(url) { |r| r.options.timeout = 45; r.options.open_timeout = 10 }
    raise "GET HTTP #{response.status}" unless response.success?
    JSON.parse(response.body)
  end

  class Runner
    def initialize(directory:, limit: 0.10, max_requests: 200, model: "jev-1.14.0", transport: nil)
      @directory, @limit, @max_requests, @model = directory, Float(limit), Integer(max_requests), model
      raise ArgumentError, "invalid limits" unless @limit.finite? && @limit.positive? && @max_requests.positive?
      raise ArgumentError, "only Jev models are allowed" unless @model.start_with?("jev-")
      @transport = transport || method(:post)
      FileUtils.mkdir_p(File.join(directory, "responses"))
    end

    def call(state:, questions: PILOT_QUESTIONS, replicate: nil)
      payload = { "model" => @model, "state" => state, "questions" => questions }
      body = JSON.generate(payload)
      raise ArgumentError, "input exceeds experiment limit" if body.bytesize > 24_000
      key = Digest::SHA256.hexdigest(JSON.generate([payload, replicate]))
      path = File.join(@directory, "responses", "#{key}.json")
      File.open(File.join(@directory, "run.lock"), "w") do |lock|
        lock.flock(File::LOCK_EX)
        if File.exist?(path)
          record = JSON.parse(File.read(path))
          validate_model!(record.fetch("response"))
          return record.merge("cache_hit" => true)
        end

        ledger_path = File.join(@directory, "ledger.json")
        ledger = File.exist?(ledger_path) ? JSON.parse(File.read(ledger_path)) : {}
        # Reserve a byte per token plus framing before sending; unknown outcomes retain the reservation.
        reserve = (body.bytesize + 4096) * PRICE / 1_000_000
        raise "request limit reached" if ledger.size >= @max_requests
        raise "spending limit reached" if ledger.values.sum { |entry| entry.fetch("usd") } + reserve > @limit
        attempt = "#{key}-#{ledger.size}"
        ledger[attempt] = { "status" => "reserved", "usd" => reserve, "at" => Time.now.utc.iso8601 }
        write_json(ledger_path, ledger)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @transport.call(payload)
        latency = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        tokens = response.dig("usage", "input_tokens")
        raise "invalid token usage" unless tokens.is_a?(Integer) && tokens >= 0 && tokens <= body.bytesize + 4096
        validate_model!(response)
        questions.each do |name, question|
          answer = response.fetch("answers").fetch(name.to_s)
          type = question[:type] || question["type"]
          values = type == "noul" ? [answer.fetch("noul")] : answer.fetch("probabilities").values
          raise "invalid probabilities" unless values.all? { |v| v.is_a?(Numeric) && v.finite? && v.between?(0, 1) }
        end
        record = { "request" => payload, "response" => response, "latency_seconds" => latency,
          "at" => Time.now.utc.iso8601, "cost_usd" => tokens * PRICE / 1_000_000,
          "replicate" => replicate, "key" => key }
        write_json(path, record)
        ledger[attempt].merge!("status" => "complete", "usd" => record.fetch("cost_usd"), "input_tokens" => tokens)
        write_json(ledger_path, ledger)
        record.merge("cache_hit" => false)
      end
    end

    def validate_model!(response)
      raise "unexpected response model" unless response.fetch("model") == @model
    end

    def write_json(path, value)
      File.write("#{path}.tmp", JSON.pretty_generate(value) + "\n")
      File.rename("#{path}.tmp", path)
    end

    def post(payload)
      key = ENV.fetch("JEV_API_KEY")
      raise "JEV_API_KEY is empty" if key.empty?
      response = Faraday.post(API) do |request|
        request.headers["Authorization"] = "Bearer #{key}"
        request.headers["Content-Type"] = "application/json"
        request.options.timeout = 45
        request.options.open_timeout = 10
        request.body = JSON.generate(payload)
      end
      raise "Jev HTTP #{response.status}" unless response.success?
      JSON.parse(response.body)
    end
  end

  def self.run(argv, output: $stdout, transport: nil)
    options = { directory: ".claude/notes/jev/data", variants: "description,metadata", limit: 0.10,
      max_requests: 200, model: "jev-1.14.0", questions: PILOT_QUESTIONS.keys.join(",") }
    parser = OptionParser.new do |p|
      p.banner = "Usage: bundle exec ruby script/experiments/jev/run.rb INPUT.json [options]"
      p.on("--directory PATH") { |v| options[:directory] = v }
      p.on("--variants LIST") { |v| options[:variants] = v }
      p.on("--questions LIST") { |v| options[:questions] = v }
      p.on("--limit-usd N", Float) { |v| options[:limit] = v }
      p.on("--max-requests N", Integer) { |v| options[:max_requests] = v }
      p.on("--model NAME") { |v| options[:model] = v }
      p.on("--replicate NAME") { |v| options[:replicate] = v }
    end
    parser.parse!(argv)
    input = argv.shift or raise ArgumentError, parser.to_s
    variants = options[:variants].split(",")
    raise ArgumentError, "unknown variant" unless (variants - %w[description metadata readme]).empty?
    names = options[:questions].split(",")
    raise ArgumentError, "unknown question" unless (names - QUESTIONS.keys).empty? && names.any?
    questions = QUESTIONS.slice(*names)
    runner = Runner.new(**options.slice(:directory, :limit, :max_requests, :model), transport: transport)
    projects = JSON.parse(File.read(input))
    raise ArgumentError, "input must be an array" unless projects.is_a?(Array)
    projects.each do |project|
      variants.each do |variant|
        result = runner.call(state: state(project, variant), questions: questions, replicate: options[:replicate])
        output.puts JSON.generate(project: project["id"] || project["url"], variant: variant,
          key: result["key"], cached: result["cache_hit"], latency: result["latency_seconds"],
          usage: result.dig("response", "usage"), answers: result.dig("response", "answers"))
        output.flush
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    JevExperiment.run(ARGV)
  rescue StandardError => error
    message = error.message
    key = ENV["JEV_API_KEY"]
    message = message.gsub(key, "[REDACTED]") unless key.to_s.empty?
    warn "Experiment stopped (#{error.class}): #{message}"
    exit 1
  end
end
