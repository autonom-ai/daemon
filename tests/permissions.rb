require 'minitest/autorun'

require_relative 'support'

class PermissionsTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
  end

  def teardown()
    teardown_core()
  end

  def test_another_profile_and_the_session_map_are_denied()
    other_memory = File.join(@wren.directory, 'memories', 'notes.md')
    sessions_file = File.join(@root, 'agents', 'sessions.json')

    refute @marlow.can_read?(other_memory)
    refute @marlow.can_write?(other_memory)
    refute @marlow.can_read?(sessions_file)
    refute @marlow.can_write?(sessions_file)
  end

  def test_the_current_profile_is_accessible_but_env_is_not()
    memory_file = File.join(@marlow.directory, 'memories', 'notes.md')

    assert @marlow.can_read?(memory_file)
    assert @marlow.can_write?(memory_file)
    refute @marlow.can_read?(File.join(@project, '.env'))
  end

  def test_searching_the_store_is_denied()
    refute @marlow.can_search?(@root)
    assert @marlow.can_search?(@project)
  end

  def test_exec_blocks_profile_redirection_protected_deletion_and_a_foreign_cwd()
    other_memory = File.join(@wren.directory, 'memories', 'note.md')

    refute @marlow.can_exec?("printf note > #{other_memory}")
    refute @marlow.can_exec?("rm -rf #{Dir.home}")
    refute @marlow.can_exec?("rm -rf #{File.join(@root, 'source')}")
    refute @marlow.can_exec?('rm -rf /')
    refute @marlow.can_exec?('pwd', dir: File.join(@wren.directory, 'memories'))
    assert @marlow.can_exec?('git status')
  end
end
