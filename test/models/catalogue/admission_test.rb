require "test_helper"

class Catalogue::AdmissionTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(url: "https://github.com/research/admission-test", science_score: 0,
      science_score_breakdown: { "score" => 0, "breakdown" => {} }, last_synced_at: 2.days.ago)
    SyncProjectWorker.clear
    IndexSoftwareSearchWorker.clear
  end

  teardown do
    SyncProjectWorker.clear
    IndexSoftwareSearchWorker.clear
  end

  def decide(decision, reason = "Source implements a scientific numerical solver")
    Catalogue::Admission.record!(project: @project, decision: decision, reason: reason, reviewer: "operator")
  end

  test "explicit admission adds a zero-score project without changing its score or calculation" do
    calculated = @project.calculate_science_score_breakdown
    saved = @project.attributes.slice("science_score", "science_score_breakdown", "readme", "repository")
    refute Project.in_catalogue.exists?(@project.id)

    admission = decide("accepted")

    assert_equal saved, @project.reload.attributes.slice(*saved.keys)
    assert_equal calculated, @project.calculate_science_score_breakdown
    assert @project.catalogued?
    assert Project.in_catalogue.exists?(@project.id)
    refute Project.scientific.exists?(@project.id)
    assert Project.should_sync.exists?(@project.id)
    assert Project.eligible_for_brief.exists?(@project.id)
    assert @project.eligible_for_brief?
    assert_equal false, admission.evidence["included_before"]
    assert_equal true, admission.evidence["included_after"]
    assert_equal 1, Catalogue::Admission.new_entries.count
    assert_equal [@project.id], SyncProjectWorker.jobs.map { |job| job["args"].first }
  end

  test "deferral and rejection remove admission while keeping decision history" do
    decide("accepted")
    admission = decide("deferred", "Canonical representation needs checking")
    refute @project.reload.catalogued?
    refute Project.in_catalogue.exists?(@project.id)
    assert_equal ["accepted"], admission.history.pluck("decision")
    assert_equal "Source implements a scientific numerical solver", admission.history.first.fetch("reason")
    admission = decide("rejected", "The selected repository is a duplicate")
    assert_equal %w[accepted deferred], admission.history.pluck("decision")
    assert_equal 0, @project.reload.science_score
  end

  test "rejecting admission does not override a qualifying Science Score" do
    @project.update!(science_score: 30)
    admission = decide("rejected", "No separate operator admission needed")
    assert @project.reload.catalogued?
    assert admission.evidence["included_before"]
    assert admission.evidence["included_after"]
    assert_empty Catalogue::Admission.new_entries
  end

  test "identical submissions preserve the decision date and do not append history or jobs" do
    admission = decide("accepted")
    before = admission.attributes.deep_dup
    jobs = SyncProjectWorker.jobs.size
    travel 1.minute do
      repeated = decide("accepted")
      assert_equal before, repeated.reload.attributes
    end
    assert_equal jobs, SyncProjectWorker.jobs.size
  end

  test "a reason and valid decision are required before membership changes" do
    assert_raises(ActiveRecord::RecordInvalid) { decide("accepted", " ") }
    assert_raises(ActiveRecord::RecordInvalid) { decide("automatic") }
    refute @project.reload.catalogued?
    assert_empty Catalogue::Admission.all
  end

  test "owner counts follow admission, score changes and withdrawal once" do
    host = Host.create!(name: "GitHub", url: "https://github.com", kind: "github")
    owner = Owner.create!(host: host, login: "research", projects_count: 0)
    @project.update!(host: host, owner_record: owner)
    decide("accepted")
    assert_equal 0, owner.reload.projects_count
    assert_equal 1, Project.visible.in_catalogue.where(owner_id: owner.id).count
    @project.update!(science_score: 12)
    assert_equal 0, owner.reload.projects_count
    assert_equal 1, Project.visible.in_catalogue.where(owner_id: owner.id).count
    @project.update!(science_score: 30)
    assert_equal 1, owner.reload.projects_count
    decide("deferred")
    assert_equal 1, owner.reload.projects_count
    @project.update!(science_score: 0)
    assert_equal 0, owner.reload.projects_count
    assert_equal 0, Project.visible.in_catalogue.where(owner_id: owner.id).count
  end

  test "deleting a Project preserves its decision and removes active admission" do
    admission = decide("accepted")
    @project.destroy!
    assert_nil admission.reload.project_id
    assert_equal "https://github.com/research/admission-test", admission.repository_url
    assert_equal "accepted", admission.decision
    assert_empty Catalogue::Admission.accepted
  end

  test "public decision data omits the operator identity and private history" do
    admission = decide("accepted")
    refute admission.public_summary.key?(:reviewed_by)
    refute admission.public_summary.key?(:history)
    assert_equal "accepted", admission.public_summary[:decision]
  end

  test "amending an approval preserves its entry outcome" do
    decide("accepted")
    amended = decide("accepted", "Additional implementation evidence checked")
    assert amended.evidence["included_before"]
    assert amended.evidence["new_catalogue_entry"]
    assert_equal 1, Catalogue::Admission.new_entries.count
    assert_equal 1, amended.history.size
  end
end
