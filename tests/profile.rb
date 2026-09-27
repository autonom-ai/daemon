require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/profile'

class ProfileTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_profile_names_and_directories_are_listed
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow'))

    profiles = Profile.get_profiles(root: @root)

    assert_equal ['Marlow'], profiles.map { |profile| profile['name'] }
    assert_equal File.join(@root, 'agents', 'Marlow'), profiles.first['directory']
  end

  def test_set_profile_is_case_insensitive_and_creates_memories
    profile = Profile.set_profile('New_Agent', session: 'session-1', root: @root)

    assert_equal 'new_agent', profile['name']
    assert File.directory?(File.join(@root, 'agents', 'new_agent', 'memories'))
    assert File.file?(File.join(@root, 'agents', 'new_agent', 'identity.md'))
    assert_equal profile, Profile.get_profile('session-1', root: @root)
  end

  def test_existing_profile_name_keeps_its_canonical_case
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow', 'memories'))

    profile = Profile.set_profile('mArLoW', session: 'session-1', root: @root)

    assert_equal 'Marlow', profile['name']
  end

  def test_session_profile_cannot_be_changed
    Profile.set_profile('marlow', session: 'session-1', root: @root)

    assert Profile.permissions.can_set_profile?('MARLOW', session: 'session-1', root: @root)
    refute Profile.permissions.can_set_profile?('wren', session: 'session-1', root: @root)
    assert_raises(ProfileStore::Error) do
      Profile.set_profile('wren', session: 'session-1', root: @root)
    end
  end

  def test_direct_access_to_another_profile_and_session_map_is_denied
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    sessions_file = File.join(@root, 'agents', 'sessions.json')

    refute Profile.permissions.can_read?(other_profile, session: 'session-1', root: @root)
    refute Profile.permissions.can_write?(other_profile, session: 'session-1', root: @root)
    refute Profile.permissions.can_read?(sessions_file, session: 'session-1', root: @root)
    refute Profile.permissions.can_write?(sessions_file, session: 'session-1', root: @root)
  end

  def test_current_profile_is_accessible_but_env_is_not
    profile = Profile.set_profile('marlow', session: 'session-1', root: @root)
    memory_file = File.join(profile['directory'], 'memories', 'notes.md')

    assert Profile.permissions.can_read?(memory_file, session: 'session-1', root: @root)
    assert Profile.permissions.can_write?(memory_file, session: 'session-1', root: @root)
    refute Profile.permissions.can_read?(File.join(@root, '.env'), session: 'session-1', root: @root)
  end

  def test_exec_blocks_profile_redirection_and_protected_deletion
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_memory = File.join(@root, 'agents', 'wren', 'memories', 'note.md')

    refute Profile.permissions.can_exec?(
      "printf note > #{other_memory}",
      session: 'session-1',
      root: @root,
      dir: @root
    )
    refute Profile.permissions.can_exec?("rm -rf #{Dir.home}", root: @root, dir: @root)
    refute Profile.permissions.can_exec?("rm -rf #{File.join(@root, 'source')}", root: @root, dir: @root)
    refute Profile.permissions.can_exec?('rm -rf /', root: @root, dir: @root)
    assert Profile.permissions.can_exec?('git status', session: 'session-1', root: @root)
  end

  def test_exec_denies_another_profile_as_working_directory
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories')

    refute Profile.permissions.can_exec?(
      'pwd',
      session: 'session-1',
      root: @root,
      dir: other_profile
    )
  end

  def test_heartbeat_is_zero_until_stamped
    Profile.set_profile('marlow', session: 'session-1', root: @root)

    assert_equal 0, Profile.heartbeat('marlow', root: @root)

    Profile.touch_heartbeat('marlow', root: @root)

    assert Profile.heartbeat('marlow', root: @root).positive?
  end
end
