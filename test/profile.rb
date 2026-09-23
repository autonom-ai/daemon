require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/core/agent/profile'

class ProfileTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_profile_names_and_directories_are_listed
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow'))

    profiles = Agent::Profile.get_profiles(root: @root)

    assert_equal ['Marlow'], profiles.map { |profile| profile['name'] }
    assert_equal File.join(@root, 'agents', 'Marlow'), profiles.first['directory']
  end

  def test_set_profile_is_case_insensitive_and_creates_memories
    profile = Agent::Profile.set_profile('New_Agent', session_id: 'session-1', root: @root)

    assert_equal 'new_agent', profile['name']
    assert File.directory?(File.join(@root, 'agents', 'new_agent', 'memories'))
    assert File.file?(File.join(@root, 'agents', 'new_agent', 'identity.md'))
    assert_equal profile, Agent::Profile.get_profile('session-1', root: @root)
  end

  def test_existing_profile_name_keeps_its_canonical_case
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow', 'memories'))

    profile = Agent::Profile.set_profile('mArLoW', session_id: 'session-1', root: @root)

    assert_equal 'Marlow', profile['name']
  end

  def test_session_profile_cannot_be_changed
    Agent::Profile.set_profile('marlow', session_id: 'session-1', root: @root)

    assert Agent::Profile.can_set_profile?('MARLOW', session_id: 'session-1', root: @root)
    refute Agent::Profile.can_set_profile?('wren', session_id: 'session-1', root: @root)
    assert_raises(Agent::Store::Error) do
      Agent::Profile.set_profile('wren', session_id: 'session-1', root: @root)
    end
  end

  def test_direct_access_to_another_profile_and_session_map_is_denied
    Agent::Profile.set_profile('marlow', session_id: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    sessions_file = File.join(@root, 'agents', 'sessions.json')

    refute Agent::Profile.can_read?(other_profile, session_id: 'session-1', root: @root)
    refute Agent::Profile.can_write?(other_profile, session_id: 'session-1', root: @root)
    refute Agent::Profile.can_read?(sessions_file, session_id: 'session-1', root: @root)
    refute Agent::Profile.can_write?(sessions_file, session_id: 'session-1', root: @root)
  end

  def test_current_profile_is_accessible_but_env_is_not
    profile = Agent::Profile.set_profile('marlow', session_id: 'session-1', root: @root)
    memory_file = File.join(profile['directory'], 'memories', 'notes.md')

    assert Agent::Profile.can_read?(memory_file, session_id: 'session-1', root: @root)
    assert Agent::Profile.can_write?(memory_file, session_id: 'session-1', root: @root)
    refute Agent::Profile.can_read?(File.join(@root, '.env'), session_id: 'session-1', root: @root)
  end

  def test_exec_blocks_profile_redirection_and_protected_deletion
    Agent::Profile.set_profile('marlow', session_id: 'session-1', root: @root)
    other_memory = File.join(@root, 'agents', 'wren', 'memories', 'note.md')

    refute Agent::Profile.can_exec?(
      "printf note > #{other_memory}",
      session_id: 'session-1',
      root: @root,
      working_directory: @root
    )
    refute Agent::Profile.can_exec?("rm -rf #{Dir.home}", root: @root, working_directory: @root)
    refute Agent::Profile.can_exec?('rm -rf /', root: @root, working_directory: @root)
    assert Agent::Profile.can_exec?('git status', session_id: 'session-1', root: @root)
  end

  def test_exec_denies_another_profile_as_working_directory
    Agent::Profile.set_profile('marlow', session_id: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories')

    refute Agent::Profile.can_exec?(
      'pwd',
      session_id: 'session-1',
      root: @root,
      working_directory: other_profile
    )
  end

  def test_migration_moves_root_markdown_except_identity
    profile_directory = File.join(@root, 'agents', 'marlow')
    FileUtils.mkdir_p(profile_directory)
    File.write(File.join(profile_directory, 'identity.md'), 'identity')
    File.write(File.join(profile_directory, 'memory.md'), 'memory')
    File.write(File.join(profile_directory, 'notes.md'), 'notes')
    File.write(File.join(profile_directory, 'tool.py'), 'script')

    Agent::Store.migrate_memories!(root: @root)

    assert File.file?(File.join(profile_directory, 'identity.md'))
    assert File.file?(File.join(profile_directory, 'memories', 'memory.md'))
    assert File.file?(File.join(profile_directory, 'memories', 'notes.md'))
    assert File.file?(File.join(profile_directory, 'tool.py'))
    refute File.exist?(File.join(profile_directory, 'memory.md'))
  end
end
