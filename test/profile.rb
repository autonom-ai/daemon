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
    profile = Agent::Profile.set_profile('New_Agent', session: 'session-1', root: @root)

    assert_equal 'new_agent', profile['name']
    assert File.directory?(File.join(@root, 'agents', 'new_agent', 'memories'))
    assert File.file?(File.join(@root, 'agents', 'new_agent', 'identity.md'))
    assert_equal profile, Agent::Profile.get_profile('session-1', root: @root)
  end

  def test_existing_profile_name_keeps_its_canonical_case
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow', 'memories'))

    profile = Agent::Profile.set_profile('mArLoW', session: 'session-1', root: @root)

    assert_equal 'Marlow', profile['name']
  end

  def test_session_profile_cannot_be_changed
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)

    assert Agent::Profile.permissions.can_set_profile?('MARLOW', session: 'session-1', root: @root)
    refute Agent::Profile.permissions.can_set_profile?('wren', session: 'session-1', root: @root)
    assert_raises(Agent::Store::Error) do
      Agent::Profile.set_profile('wren', session: 'session-1', root: @root)
    end
  end

  def test_direct_access_to_another_profile_and_session_map_is_denied
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    sessions_file = File.join(@root, 'agents', 'sessions.json')

    refute Agent::Profile.permissions.can_read?(other_profile, session: 'session-1', root: @root)
    refute Agent::Profile.permissions.can_write?(other_profile, session: 'session-1', root: @root)
    refute Agent::Profile.permissions.can_read?(sessions_file, session: 'session-1', root: @root)
    refute Agent::Profile.permissions.can_write?(sessions_file, session: 'session-1', root: @root)
  end

  def test_current_profile_is_accessible_but_env_is_not
    profile = Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    memory_file = File.join(profile['directory'], 'memories', 'notes.md')

    assert Agent::Profile.permissions.can_read?(memory_file, session: 'session-1', root: @root)
    assert Agent::Profile.permissions.can_write?(memory_file, session: 'session-1', root: @root)
    refute Agent::Profile.permissions.can_read?(File.join(@root, '.env'), session: 'session-1', root: @root)
  end

  def test_exec_blocks_profile_redirection_and_protected_deletion
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_memory = File.join(@root, 'agents', 'wren', 'memories', 'note.md')

    refute Agent::Profile.permissions.can_exec?(
      "printf note > #{other_memory}",
      session: 'session-1',
      root: @root,
      dir: @root
    )
    refute Agent::Profile.permissions.can_exec?("rm -rf #{Dir.home}", root: @root, dir: @root)
    refute Agent::Profile.permissions.can_exec?('rm -rf /', root: @root, dir: @root)
    assert Agent::Profile.permissions.can_exec?('git status', session: 'session-1', root: @root)
  end

  def test_exec_denies_another_profile_as_working_directory
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    other_profile = File.join(@root, 'agents', 'wren', 'memories')

    refute Agent::Profile.permissions.can_exec?(
      'pwd',
      session: 'session-1',
      root: @root,
      dir: other_profile
    )
  end

  def test_dms_and_pings_are_profile_scoped
    Agent::Profile.dm('marlow', 'first', from: 'wren', root: @root)
    Agent::Profile.ping('marlow', 'look here', from: 'wren', room: 'general', root: @root)

    inbox = Agent::Profile.inbox('marlow', root: @root)
    pings = Agent::Profile.pings('marlow', root: @root)

    assert_equal ['first'], inbox.map { |entry| entry['text'] }
    assert_equal 'marlow', inbox.first['to']
    assert_equal ['look here'], pings.map { |entry| entry['text'] }
    assert_equal 'general', pings.first['room']
    assert File.file?(File.join(@root, 'agents', 'marlow', 'inbox.jsonl'))
    assert_empty Agent::Profile.inbox('wren', root: @root)
  end

  def test_read_pings_delivers_each_ping_once
    Agent::Profile.ping('marlow', 'look here', from: 'wren', room: 'general', root: @root)
    Agent::Profile.ping('marlow', 'and here', from: 'sable', root: @root)

    assert_equal ['look here', 'and here'], Agent::Profile.read_pings('marlow', root: @root).map { |ping| ping['text'] }
    assert_empty Agent::Profile.read_pings('marlow', root: @root)
    assert_equal 2, Agent::Profile.pings('marlow', root: @root).length
  end

  def test_reads_advance_cursors_and_a_first_read_starts_with_a_window
    3.times { |index| Agent::Profile.dm('marlow', "dm #{index}", from: 'wren', root: @root) }

    first = Agent::Profile.read_inbox('marlow', limit: 2, root: @root)

    assert_equal ['dm 1', 'dm 2'], first.map { |entry| entry['text'] }
    assert_empty Agent::Profile.read_inbox('marlow', root: @root)

    Agent::Profile.dm('marlow', 'dm 3', from: 'wren', root: @root)
    assert_equal ['dm 3'], Agent::Profile.read_inbox('marlow', root: @root).map { |entry| entry['text'] }
  end

  def test_unread_reads_do_not_advance_the_cursor
    Agent::Profile.dm('marlow', 'dm', from: 'wren', root: @root)

    assert_equal 1, Agent::Profile.unread_inbox('marlow', root: @root).length
    assert_equal 1, Agent::Profile.unread_inbox('marlow', root: @root).length
    assert_equal 1, Agent::Profile.read_inbox('marlow', root: @root).length
    assert_empty Agent::Profile.unread_inbox('marlow', root: @root)
  end

  def test_waiting_gathers_undrained_signals
    Agent::Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Agent::Profile.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', root: @root)

    waiting = Agent::Profile.waiting('marlow', rooms: ['general'], rooms_root: @root, root: @root)

    assert_equal ['ping text'], waiting['pings'].map { |entry| entry['text'] }
    assert_equal ['dm text'], waiting['inbox'].map { |entry| entry['text'] }
    assert_equal ['room text'], waiting['rooms']['general'].map { |entry| entry['text'] }
    assert_equal 1, Agent::Profile.unread_pings('marlow', root: @root).length
  end

  def test_chat_names_are_validated
    assert_raises(Agent::Store::Error) { Agent::Profile.dm('../wren', 'hi', from: 'marlow', root: @root) }
    assert_raises(Agent::Store::Error) { Agent::Profile.ping('..', 'hi', from: 'marlow', root: @root) }
  end
end
