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
    other_file = File.join(@wren.directory, 'notes.md')
    sessions_file = File.join(@root, 'agents', 'sessions.json')

    refute @marlow.can_read?(other_file)
    refute @marlow.can_write?(other_file)
    refute @marlow.can_read?(sessions_file)
    refute @marlow.can_write?(sessions_file)
  end

  def test_the_current_profile_is_accessible_but_env_is_not()
    profile_file = File.join(@marlow.directory, 'notes.md')

    assert @marlow.can_read?(profile_file)
    assert @marlow.can_write?(profile_file)
    refute @marlow.can_read?(File.join(@project, '.env'))
  end

  def test_last_room_selection_cannot_be_changed_directly()
    refute @marlow.can_write?(File.join(@marlow.directory, 'room.json'))
  end

  def test_searching_the_store_is_denied()
    refute @marlow.can_search?(@root)
    assert @marlow.can_search?(@project)
  end

  def test_exec_blocks_profile_redirection_protected_deletion_and_a_foreign_cwd()
    other_file = File.join(@wren.directory, 'note.md')

    refute @marlow.can_exec?("printf note > #{other_file}")
    refute @marlow.can_exec?("rm -rf #{Dir.home}")
    refute @marlow.can_exec?("rm -rf #{File.join(@root, 'source')}")
    refute @marlow.can_exec?('rm -rf /')
    refute @marlow.can_exec?('pwd', dir: @wren.directory)
    assert @marlow.can_exec?('git status')
  end

  def test_the_codebase_guard_bans_root_edits_for_everyone_not_exempt()
    quill = ProfileStore.register_profile('quill', 'session-3')
    sable = ProfileStore.register_profile('sable', 'session-4')
    source_file = File.join(@root, 'source', 'hooks.rb')

    refute quill.can_write?(File.join(@root, 'README.md'))
    refute quill.can_write?(source_file)
    refute Unclaimed.new().can_write?(source_file)

    # sable, wren and marlow are on the default template's except list.
    assert sable.can_write?(source_file)
    assert @wren.can_write?(source_file)
    assert @marlow.can_write?(source_file)

    # Reading the codebase is not editing it.
    assert quill.can_read?(source_file)
  end

  def test_a_workspace_file_without_guards_leaves_access_open()
    FileUtils.mkdir_p(File.dirname(Workspace.policy_path))
    File.write(Workspace.policy_path, "access: []\nrules: []\n")

    assert @marlow.can_write?(File.join(@root, 'README.md'))
    assert @marlow.can_read?(File.join(@project, '.env'))
  end

  def test_room_files_are_gated_by_membership()
    write_room('general', owner: 'marlow')
    dir = File.join(@project, '.devin', 'autonom-coord', 'rooms', 'general')

    assert @marlow.can_read?(File.join(dir, 'messages.jsonl'))
    assert @marlow.can_write?(File.join(dir, 'messages.jsonl'))
    assert @wren.can_read?(File.join(dir, 'messages.jsonl'))
    assert @marlow.can_write?(File.join(dir, 'policy.yml'))
    assert @wren.can_read?(File.join(dir, 'policy.yml'))
    refute @wren.can_write?(File.join(dir, 'policy.yml'))
    refute @wren.can_read?(File.join(dir, 'profiles.json'))
    refute @marlow.can_read?(File.join(dir, 'profiles.json'))
  end

  def test_a_hidden_room_is_excluded_from_search()
    write_room('secret', owner: 'marlow', involved: ['marlow'])

    refute @wren.can_search?(@project)
    assert @marlow.can_search?(@project)
  end
end
