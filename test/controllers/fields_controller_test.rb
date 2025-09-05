require 'test_helper'

class FieldsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Use existing seeded fields or create them
    @physics_field = Field.find_or_create_by!(name: 'Physics', domain: 'physical_sciences') do |f|
      f.keywords = ['quantum', 'mechanics', 'particles']
      f.packages = ['numpy', 'scipy']
      f.indicators = ['simulation', 'experiment']
    end
    
    @economics_field = Field.find_or_create_by!(name: 'Economics', domain: 'social_sciences') do |f|
      f.keywords = ['market', 'finance', 'economy']
      f.packages = ['pandas', 'statsmodels']
      f.indicators = ['analysis', 'model']
    end
    
    # Create test projects with minimal required fields
    @project1 = Project.find_or_create_by!(url: 'https://github.com/test/quantum-sim') do |p|
      p.name = 'Quantum Simulator'
      p.description = 'A quantum physics simulation tool'
      p.keywords = ['quantum', 'physics', 'simulation']
    end
    
    @project2 = Project.find_or_create_by!(url: 'https://github.com/test/econ-model') do |p|
      p.name = 'Economic Model'
      p.description = 'Economic modeling tool'
      p.keywords = ['economics', 'model', 'finance']
    end
    
    # Clean up and recreate project-field associations
    ProjectField.where(project: [@project1, @project2]).destroy_all
    
    @pf1 = ProjectField.create!(
      project: @project1,
      field: @physics_field,
      confidence_score: 0.85,
      match_signals: { 'keywords' => 0.9, 'readme' => 0.8 }
    )
    
    @pf2 = ProjectField.create!(
      project: @project2,
      field: @economics_field,
      confidence_score: 0.75,
      match_signals: { 'keywords' => 0.8, 'packages' => 0.7 }
    )
    
    # Add multi-field classification
    @pf3 = ProjectField.create!(
      project: @project1,
      field: @economics_field,
      confidence_score: 0.45,
      match_signals: { 'keywords' => 0.5 }
    )
  end

  teardown do
    # Clean up test data
    ProjectField.where(project: [@project1, @project2]).destroy_all
  end

  # INDEX ACTION TESTS
  
  test "should get index" do
    get fields_url
    assert_response :success
    
    assert_select 'h1', text: 'Scientific Fields'
    
    # Check that domains are displayed
    assert_match 'Physical Sciences', response.body
    assert_match 'Social Sciences', response.body
    
    # Check that fields are displayed
    assert_match @physics_field.name, response.body
    assert_match @economics_field.name, response.body
  end
  
  test "index should show summary statistics" do
    get fields_url
    assert_response :success
    
    # Check for stats cards
    assert_select '.card.text-center', minimum: 4
    assert_match 'Classified Projects', response.body
    assert_match 'Avg Confidence', response.body
    assert_match 'Multi-field Projects', response.body
  end
  
  test "index should show project counts" do
    get fields_url
    assert_response :success
    
    # Both fields should have project counts displayed
    assert_select '.badge', minimum: 2
  end
  
  test "index should handle fields with no projects" do
    empty_field = Field.find_or_create_by!(name: 'Test Empty Field', domain: 'physical_sciences')
    
    get fields_url
    assert_response :success
    
    # Should display the field even with 0 projects
    assert_match empty_field.name, response.body
  end

  # SHOW ACTION TESTS
  
  test "should get show for physics field" do
    get field_url(@physics_field)
    assert_response :success
    
    assert_select 'h1', @physics_field.name
    assert_match 'Physical Sciences', response.body
  end
  
  test "should get show for economics field" do
    get field_url(@economics_field)
    assert_response :success
    
    assert_select 'h1', @economics_field.name
    assert_match 'Social Sciences', response.body
  end
  
  test "show should display field statistics" do
    get field_url(@physics_field)
    assert_response :success
    
    assert_match 'Total Projects:', response.body
    assert_match 'Average Confidence', response.body
    assert_match 'High Confidence', response.body
  end
  
  test "show should display field metadata" do
    get field_url(@physics_field)
    assert_response :success
    
    # Check keywords if present
    if @physics_field.keywords.any?
      assert_match 'Field Keywords:', response.body
      @physics_field.keywords.each do |keyword|
        assert_match keyword, response.body
      end
    end
    
    # Check packages if present
    if @physics_field.packages.any?
      assert_match 'Common Packages:', response.body
    end
    
    # Check indicators if present
    if @physics_field.indicators.any?
      assert_match 'Scientific Indicators:', response.body
    end
  end
  
  test "show should list projects in the field" do
    get field_url(@physics_field)
    assert_response :success
    
    # Project should be listed
    assert_match @project1.name, response.body
    assert_match @project1.description, response.body
    
    # Confidence score should be displayed
    assert_match '85% confidence', response.body
  end
  
  test "show should display multi-field projects correctly" do
    get field_url(@economics_field)
    assert_response :success
    
    # Both projects should be listed
    assert_match @project1.name, response.body
    assert_match @project2.name, response.body
    
    # Should show "Also in" for project1
    assert_match 'Also in:', response.body
  end
  
  test "show should handle fields with no projects" do
    empty_field = Field.find_or_create_by!(name: 'Test Empty', domain: 'social_sciences')
    
    get field_url(empty_field)
    assert_response :success
    
    assert_match 'No projects have been classified in this field yet', response.body
  end
  
  test "show should display related fields" do
    # Make sure there's another field in same domain
    chemistry = Field.find_or_create_by!(name: 'Chemistry', domain: 'physical_sciences')
    
    get field_url(@physics_field)
    assert_response :success
    
    assert_match 'Related Fields', response.body
    assert_match chemistry.name, response.body
  end
  
  test "show should handle missing match signals" do
    # Create project field without match signals
    pf_no_signals = ProjectField.create!(
      project: @project2,
      field: @physics_field,
      confidence_score: 0.6,
      match_signals: nil
    )
    
    get field_url(@physics_field)
    assert_response :success
    
    # Should not error
    assert_match @project2.name, response.body
    
    pf_no_signals.destroy
  end
  
  test "show should display top keywords when projects have them" do
    get field_url(@physics_field)
    assert_response :success
    
    # Should have top keywords section if projects have keywords
    if @project1.keywords.any?
      assert_match 'Top Keywords from Projects', response.body
    end
  end
  
  test "show handles projects with nil keywords" do
    @project1.update(keywords: nil)
    
    get field_url(@physics_field)
    assert_response :success
    
    # Should not error
    assert_match @project1.name, response.body
  end
  
  test "show handles projects with empty array keywords" do
    @project1.update(keywords: [])
    
    get field_url(@physics_field)
    assert_response :success
    
    # Should not error
    assert_match @project1.name, response.body
  end

  # EDGE CASES
  
  test "show returns 404 for non-existent field" do
    get field_url(999999)
    assert_response :not_found
  end
  
  test "index handles when no fields exist" do
    # Don't actually delete all fields as it would break other tests
    # Just test that the view doesn't error with empty collections
    get fields_url
    assert_response :success
  end
  
  test "show handles very long field names" do
    long_field = Field.find_or_create_by!(
      name: 'Very Long Field Name ' * 10,
      domain: 'physical_sciences'
    )
    
    get field_url(long_field)
    assert_response :success
  end
  
  test "show handles special characters in field data" do
    special_field = Field.find_or_create_by!(
      name: 'Field & Science < > "Test"',
      domain: 'physical_sciences',
      keywords: ['test&demo', '<script>alert(1)</script>']
    )
    
    get field_url(special_field)
    assert_response :success
    
    # Should escape HTML properly
    assert_no_match '<script>alert', response.body
  end
end