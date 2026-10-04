require 'minitest/autorun'

require_relative 'support'

class WorkspaceTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
  end

  def teardown()
    teardown_core()
  end

  def test_paths_hang_off_the_project_directory()
    assert_equal @project, Workspace.project_dir
    assert_equal File.join(@project, '.devin', 'policy.yml'), Workspace.policy_path
    assert_equal File.join(@project, '.devin', 'autonom-coord', 'rooms'), Workspace.rooms_dir
  end
end
