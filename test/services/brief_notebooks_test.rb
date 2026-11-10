require "test_helper"

class BriefNotebooksTest < ActiveSupport::TestCase
  test "repository scans use the released Brief with scientific tool detection and text READMEs" do
    Dir.mktmpdir("brief-release-") do |directory|
      File.write(File.join(directory, "pyproject.toml"), "[project]\nname = \"research\"\nversion = \"1.0\"\ndependencies = [\"PyMoDAQ\"]\n")
      File.write(File.join(directory, "snakefile"), "rule all:\n    input: []\n")
      File.write(File.join(directory, "README.html"), "<p>Rendered documentation</p>\n")
      File.write(File.join(directory, "README.md"), "# Research software\n")

      report = RepositoryBriefScan.call(directory)
      names = report.fetch("tools").values.flatten.map { |tool| tool.fetch("name") }

      assert_equal "0.16.0", report.fetch("version")
      assert_equal Gem::Version.new(report.fetch("version")), BriefRescanEnqueuer.current_version
      assert_includes names, "PyMoDAQ"
      assert_includes names, "Snakemake"
      assert_equal "README.md", RepositoryResources.resource_paths(report).fetch("readme")
      assert_equal %w[dependencies languages lines manifests package_managers resources tools version], report.keys.sort
    end
  end

  test "installed notebook binary separates code from saved output and detects Jupytext YAML" do
    Dir.mktmpdir("brief-notebooks-") do |directory|
      File.write(File.join(directory, "analysis.ipynb"), JSON.generate({
        "nbformat" => 4,
        "metadata" => { "kernelspec" => { "language" => "python" } },
        "cells" => [{ "cell_type" => "code", "source" => ["print(1)\n"],
          "outputs" => [{ "output_type" => "stream", "name" => "stdout", "text" => "saved output\n" * 1_000 }] }]
      }))
      File.write(File.join(directory, "jupytext.yaml"), "formats: ipynb,py:percent\n")

      output = RepositoryCommand.new(timeout: 120, output_limit: 1.megabyte)
        .run(["brief-notebooks", "--json", "--notebooks", directory])
      report = JSON.parse(output)
      notebook = report.fetch("notebooks").fetch("files").sole

      assert_equal "0.16.0", report.fetch("version")
      assert_equal "ok", notebook.fetch("status")
      assert_equal "python", notebook.fetch("language")
      assert_equal 1, notebook.fetch("code_cells")
      assert_equal 1, notebook.fetch("code_lines")
      assert_equal 9, notebook.fetch("code_bytes")
      assert_operator notebook.fetch("output_bytes"), :>, 1_000
      refute_includes JSON.generate(notebook), "saved output"
      assert_equal ["jupytext.yaml"], report.fetch("tools").fetch("format")
        .find { |tool| tool.fetch("name") == "Jupytext" }.fetch("config_files")
    end
  end
end
