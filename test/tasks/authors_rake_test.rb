require "test_helper"
require "rake"

class AuthorsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(
      "authors:sync_public_evidence_counts"
    )
    ENV.delete("LIMIT")
    ENV.delete("AFTER_ID")
  end

  teardown do
    ENV.delete("LIMIT")
    ENV.delete("AFTER_ID")
  end

  test "sync_public_evidence_counts refreshes a bounded author batch" do
    author = Author.create!(
      canonical_key: "email:rake@example.edu",
      display_name: "Rake Author"
    )
    project = Project.create!(
      url: "https://github.com/evidence/rake",
      science_score: Project::SCIENCE_SCORE_THRESHOLD
    )
    ProjectAuthor.create!(
      project: project,
      author: author,
      source: "citation_cff",
      authorship_kind: "software",
      author_kind: "person",
      position: 1,
      display_name: author.display_name,
      source_path: "authors[0]",
      source_digest: "rake-author"
    )
    ENV["LIMIT"] = "1"
    ENV["AFTER_ID"] = (author.id - 1).to_s

    output, = capture_io do
      Rake::Task["authors:sync_public_evidence_counts"].execute
    end

    assert_equal 1, author.reload.public_evidence_count
    assert_includes output, "selected: 1"
    assert_includes output, "updated: 1"
    assert_includes output, "next_after_id: #{author.id}"
  end
end
