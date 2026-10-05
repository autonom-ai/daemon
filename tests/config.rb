require 'minitest/autorun'

require_relative 'support'

class ConfigTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
  end

  def teardown()
    teardown_core()
  end

  def test_paths_hang_off_the_project_directory()
    assert_equal @project, Config.project_dir
    assert_equal File.join(@project, '.devin', 'policy.yml'), Config.policy_path
    assert_equal File.join(@project, '.devin', 'hooks.v1.json'), Config.hooks_path
    assert_equal File.join(@project, '.devin', 'autonom-coord', 'rooms'), Config.rooms_dir
  end

  def test_the_workspace_policy_is_present_only_when_the_file_exists()
    assert Config.has_policy?

    File.unlink(Config.policy_path)

    refute Config.has_policy?
  end

  def test_a_symlinked_policy_is_not_present()
    target = File.join(@project, 'policy.yml')
    File.rename(Config.policy_path, target)
    File.symlink(target, Config.policy_path)

    refute Config.has_policy?
  end

  def test_the_hooks_are_present_only_when_the_file_exists()
    refute Config.has_hooks?

    File.write(Config.hooks_path, "{}\n")

    assert Config.has_hooks?
  end

  def test_a_symlinked_hooks_file_is_not_present()
    target = File.join(@project, 'hooks.json')
    File.write(target, "{}\n")
    File.symlink(target, Config.hooks_path)

    refute Config.has_hooks?
  end
end
