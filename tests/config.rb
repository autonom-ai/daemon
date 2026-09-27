require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/config'

class ConfigTest < Minitest::Test
  def setup
    @project = Dir.mktmpdir('autonom-project')
  end

  def teardown
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_missing_config_keeps_the_defaults
    config = Config.load(project: @project)

    assert_equal @project, config['project_dir']
    assert_nil config['team_room']
    assert config['policy']['enabled']
    assert config['salience']['enabled']
    refute config['memory']['enabled']
  end

  def test_values_and_directories_come_from_the_workspace
    write_config('project' => 'jobs', 'human' => 'cet', 'teamRoom' => 'Market')

    config = Config.load(project: @project)

    assert_equal 'jobs', config['project']
    assert_equal 'cet', config['human']
    assert_equal 'Market', config['team_room']
    assert_equal File.join(@project, '.devin', 'autonom-config.json'), Config.path(project: @project)
    assert_equal File.join(@project, '.devin', 'autonom-coord', 'rooms'), Config.rooms_dir(project: @project)
    assert_equal 'Market', Config.team_room(project: @project)
  end

  def test_a_feature_is_a_backend_name_a_hash_or_a_switch
    write_config(
      'policy' => 'typesafe',
      'salience' => { 'enabled' => false, 'backend' => 'decider' },
      'memory' => false
    )

    config = Config.load(project: @project)

    assert config['policy']['enabled']
    assert_equal 'typesafe', config['policy']['backend']
    refute config['salience']['enabled']
    assert_equal 'decider', config['salience']['backend']
    refute config['memory']['enabled']
  end

  def test_a_malformed_config_is_ignored
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), 'not json')

    config = Config.load(project: @project)

    assert_nil config['project']
    assert config['policy']['enabled']
  end

  private

  def write_config(values)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(values))
  end
end
