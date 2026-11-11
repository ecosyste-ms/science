#!/usr/bin/env ruby

require_relative "run"

module JevAnalysis
  def self.probabilities(answers)
    values = answers.filter_map { |name, answer| [name, answer["noul"]] if answer.key?("noul") }.to_h
    if answers["kind"]
      distribution = answers.fetch("kind").fetch("probabilities")
      values["category"] = distribution.fetch("research") + distribution.fetch("research_workflow")
    end
    if values["strict"] && values["education"]
      values["strict_without_education"] = [values["strict"], 1 - values["education"]].min
    end
    if values["workflow"] && values["general"]
      values["workflow_without_general"] = [values["workflow"], 1 - values["general"]].min
    end
    values.except("general", "education")
  end

  def self.metrics(rows, threshold)
    known = rows.reject { |r| r[:label].nil? }
    tp = known.count { |r| r[:label] && r[:p] >= threshold }
    fp = known.count { |r| !r[:label] && r[:p] >= threshold }
    fn = known.count { |r| r[:label] && r[:p] < threshold }
    tn = known.size - tp - fp - fn
    { n: known.size, tp: tp, fp: fp, fn: fn, tn: tn,
      accuracy: known.empty? ? nil : (tp + tn).fdiv(known.size),
      precision: tp + fp == 0 ? nil : tp.fdiv(tp + fp),
      recall: tp + fn == 0 ? nil : tp.fdiv(tp + fn),
      brier: known.empty? ? nil : known.sum { |r| (r[:p] - (r[:label] ? 1 : 0))**2 }.fdiv(known.size),
      false_positives: known.select { |r| !r[:label] && r[:p] >= threshold }.map { |r| r[:id] },
      false_negatives: known.select { |r| r[:label] && r[:p] < threshold }.map { |r| r[:id] } }
  end

  def self.mean_predictions(rows)
    rows.group_by { |row| row[:id] }.values.map do |predictions|
      strategies = predictions.flat_map { |row| row[:probabilities].keys }.uniq
      probabilities = strategies.to_h do |strategy|
        values = predictions.filter_map { |row| row[:probabilities][strategy] }
        [strategy, values.sum.fdiv(values.size)]
      end
      predictions.first.slice(:id, :label, :score, :vocabulary).merge(
        probabilities: probabilities, predictions: predictions.size)
    end
  end

  def self.run(sample_path, observations_path, directory)
    projects = JSON.parse(File.read(sample_path)).to_h { |p| [p["id"] || p["url"], p] }
    observations = File.readlines(observations_path).map { |line| JSON.parse(line) }
    records = observations.map { |r| r.fetch("key") }.uniq.to_h do |key|
      [key, JSON.parse(File.read(File.join(directory, "responses", "#{key}.json")))]
    end
    variants = observations.group_by { |r| r.fetch("variant") }.transform_values do |observed|
      predictions = observed.uniq { |item| item.values_at("project", "key") }.map do |item|
        project = projects.fetch(item.fetch("project"))
        { id: project["id"] || project["url"], label: project["manual_label"], score: project["science_score"],
          vocabulary: project.dig("science_score_breakdown", "breakdown", "joss_vocabulary_similarity", "score"),
          probabilities: probabilities(item.fetch("answers")), replicate: records.fetch(item.fetch("key"))["replicate"] }
      end
      rows = mean_predictions(predictions)
      replicates = predictions.group_by { |row| row[:replicate] }.transform_values { |values| mean_predictions(values) }
      strategies = rows.flat_map { |r| r[:probabilities].keys }.uniq.to_h do |strategy|
        selected = rows.filter_map { |r| r.merge(p: r[:probabilities][strategy]) if r[:probabilities].key?(strategy) }
        [strategy, { at_50: metrics(selected, 0.5), at_80: metrics(selected, 0.8),
          per_replicate: replicates.map do |replicate, values|
            values = values.filter_map { |row| row.merge(p: row[:probabilities][strategy]) if row[:probabilities].key?(strategy) }
            { replicate: replicate, at_50: metrics(values, 0.5), at_80: metrics(values, 0.8) }
          end,
          below_20: metrics(selected.select { |r| !r[:score].nil? && r[:score] < 20 }, 0.5),
          vocabulary_below_30: metrics(selected.select { |r| !r[:vocabulary].nil? && r[:vocabulary] < 30 }, 0.5),
          calibration: [[0, 0.2], [0.2, 0.5], [0.5, 0.8], [0.8, 1.01]].map do |low, high|
            bin = selected.select { |r| !r[:label].nil? && r[:p] >= low && r[:p] < high }
            { range: [low, [high, 1].min], n: bin.size,
              mean_probability: bin.empty? ? nil : bin.sum { |r| r[:p] }.fdiv(bin.size),
              positive_rate: bin.empty? ? nil : bin.count { |r| r[:label] }.fdiv(bin.size) }
          end }]
      end
      { n: rows.size, strategies: strategies,
        score_baseline: metrics(rows.reject { |r| r[:score].nil? }.map { |r| r.merge(p: r[:score] >= 20 ? 1 : 0) }, 0.5).except(:brier),
        rows: rows }
    end
    records = records.values
    latencies = records.map { |r| r.fetch("latency_seconds") }.sort
    usage = records.map { |r| r.dig("response", "usage", "input_tokens") }
    costs = variants.to_h do |variant, _|
      keys = observations.select { |o| o["variant"] == variant }.map { |r| r["key"] }.uniq
      tokens = keys.map { |key| records.find { |r| r["key"] == key }.dig("response", "usage", "input_tokens") }
      mean = tokens.sum.fdiv(tokens.size)
      [variant, { mean_tokens: mean, projects: [10_000, 250_000, 1_000_000].to_h { |n| [n, mean * n * JevExperiment::PRICE / 1_000_000] } }]
    end
    { variants: variants, requests: records.size, input_tokens: usage.sum,
      output_tokens: records.sum { |r| r.dig("response", "usage", "output_tokens") },
      cost_usd: records.sum { |r| r["cost_usd"] },
      latency_seconds: { p50: latencies[(latencies.size * 0.5).floor], p95: latencies[(latencies.size * 0.95).floor],
        total: latencies.sum }, estimates: costs }
  end
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(JevAnalysis.run(*ARGV))
end
