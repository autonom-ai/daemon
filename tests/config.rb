require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/config'

class ConfigTest < Minitest::Test
  def setup()
    @project = Dir.mktmpdir('autonom-project')
    @previous_project = ENV['DEVIN_PROJECT_DIR']
    ENV['DEVIN_PROJECT_DIR'] = @project
  end

  def teardown()
    ENV['DEVIN_PROJECT_DIR'] = @previous_project
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_missing_config_keeps_the_defaults()
    assert_equal @project, Config.project_dir
    assert_nil Config.default_room
    assert Config.policy.enabled?
    assert Config.salience.enabled?
    refute Config.memory.enabled?
  end

  def test_values_and_directories_come_from_the_workspace()
    write_config('project' => 'jobs', 'human' => 'cet', 'defaultRoom' => 'Market')

    assert_equal 'jobs', Config.project
    assert_equal 'cet', Config.human
    assert_equal 'Market', Config.default_room
    assert_equal File.join(@project, '.devin', 'autonom-config.json'), Config.path
    assert_equal File.join(@project, '.devin', 'autonom-coord', 'rooms'), Config.rooms_dir
  end

  def test_a_feature_is_a_backend_name_a_hash_or_a_switch()
    write_config(
      'policy' => 'typesafe',
      'salience' => { 'enabled' => false, 'backend' => 'decider' },
      'memory' => false
    )

    assert Config.policy.enabled?
    assert_equal 'typesafe', Config.policy.backend
    refute Config.salience.enabled?
    assert_equal 'decider', Config.salience.backend
    refute Config.memory.enabled?
  end

  def test_a_malformed_config_is_ignored()
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), 'not json')

    assert_nil Config.project
    assert Config.policy.enabled?
  end

  private

  def write_config(values)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(values))
  end
end
