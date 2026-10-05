require 'minitest/autorun'

require_relative '../support'

class PolicyAccessTest < Minitest::Test
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

    refute read?(other_file)
    refute write?(other_file)
    refute read?(sessions_file)
    refute write?(sessions_file)
  end

  def test_the_current_profile_is_accessible_but_env_is_not()
    profile_file = File.join(@marlow.directory, 'notes.md')

    assert read?(profile_file)
    assert write?(profile_file)
    refute read?(File.join(@project, '.env'))
  end

  def test_the_profile_policy_cannot_be_changed_directly()
    refute write?(File.join(@marlow.directory, 'policies.json'))
  end

  def test_searching_the_store_is_denied()
    refute search?(@root)
    assert search?(@project)
  end

  def test_exec_blocks_profile_redirection_protected_deletion_and_a_foreign_cwd()
    other_file = File.join(@wren.directory, 'note.md')

    refute execute?("printf note > #{other_file}")
    refute execute?("rm -rf #{Dir.home}")
    refute execute?("rm -rf #{File.join(@root, 'source')}")
    refute execute?('rm -rf /')
    refute execute?('pwd', base_dir: @wren.directory)
    assert execute?('git status')
  end

  def test_write_and_execute_are_grants_not_a_codebase_guard()
    quill = ProfileStore.register_profile('quill', 'session-3')
    sable = ProfileStore.register_profile('sable', 'session-4')
    source_file = File.join(@root, 'source', 'hooks.rb')
    project_file = File.join(@project, 'notes.md')
    File.write(
      Config.policy_path,
      <<~YAML
        permissions:
          - default: [read, -write, -execute]
          - marlow: [write, execute]
          - wren: [write, execute]
          - sable: [write, execute]
        rules: []
      YAML
    )

    # quill has read only. An unclaimed session gets default and cannot write.
    refute permits?(quill.name, 'write', path: project_file)
    refute permits?(quill.name, 'write', path: source_file)
    refute permits?(nil, 'write', path: source_file)
    assert permits?(quill.name, 'read', path: source_file)
    assert permits?(nil, 'read', path: source_file)

    # sable, wren and marlow are granted write and execute.
    assert permits?(sable.name, 'write', path: source_file)
    assert write?(source_file)
    assert permits?(@wren.name, 'write', path: source_file)
    assert execute?('git status')
    refute permits?(quill.name, 'execute', command: 'git status')
  end

  def test_a_later_profile_entry_overrides_default()
    FileUtils.mkdir_p(File.dirname(Config.policy_path))
    File.write(
      Config.policy_path,
      "permissions:\n  - default: [read, -write]\n  - marlow: [write]\nrules: []\n"
    )

    assert write?(File.join(@project, 'notes.md'))
    refute permits?(@wren.name, 'write', path: File.join(@project, 'notes.md'))
    refute execute?('git status')
  end

  def test_a_workspace_file_without_permissions_denies_every_kind()
    FileUtils.mkdir_p(File.dirname(Config.policy_path))
    File.write(Config.policy_path, "permissions: []\nrules: []\n")

    refute write?(File.join(@project, 'notes.md'))
    refute read?(File.join(@project, '.env'))
    refute read?(File.join(@project, 'notes.md'))
  end

  def test_room_files_are_gated_by_membership()
    write_room('general', owner: 'marlow')
    dir = File.join(@project, '.devin', 'autonom-coord', 'rooms', 'general')

    assert read?(File.join(dir, 'messages.jsonl'))
    assert write?(File.join(dir, 'messages.jsonl'))
    assert permits?(@wren.name, 'read', path: File.join(dir, 'messages.jsonl'))
    assert write?(File.join(dir, 'policy.yml'))
    assert permits?(@wren.name, 'read', path: File.join(dir, 'policy.yml'))
    refute permits?(@wren.name, 'write', path: File.join(dir, 'policy.yml'))
    refute permits?(@wren.name, 'read', path: File.join(dir, 'profiles.json'))
    refute read?(File.join(dir, 'profiles.json'))
  end

  def test_room_membership_rules_match_path_access()
    write_room('shared', owner: 'marlow', admins: ['wren'], involved: ['quill'])
    messages = File.join(@project, '.devin', 'autonom-coord', 'rooms', 'shared', 'messages.jsonl')
    policy = File.join(@project, '.devin', 'autonom-coord', 'rooms', 'shared', 'policy.yml')
    membership = {
      'marlow' => [true, true],
      'wren' => [true, true],
      'quill' => [true, false],
      'human' => [true, true],
      'sable' => [false, false]
    }

    membership.each do |name, (visible, administrator)|
      assert_equal visible, room('shared').visible?(name)
      assert_equal visible, Policy::Access.permits?(name, 'read', path: messages)
      assert_equal visible, Policy::Access.permits?(name, 'write', path: messages)
      assert_equal administrator, Policy::Access.permits?(name, 'write', path: policy)
    end
  end

  def test_the_human_profile_remains_room_admin_when_membership_is_unreadable()
    dir = write_room('broken', owner: 'marlow', involved: ['marlow'])
    profiles = File.join(dir, 'profiles.json')
    messages = File.join(dir, 'messages.jsonl')
    policy = File.join(dir, 'policy.yml')
    File.write(profiles, 'not json')

    assert room('broken').visible?('human')
    assert Policy::Access.permits?('human', 'read', path: messages)
    assert Policy::Access.permits?('human', 'write', path: policy)
    refute room('broken').visible?('marlow')
    refute Policy::Access.permits?('marlow', 'read', path: messages)

    File.unlink(profiles)

    assert room('broken').visible?('human')
    assert Policy::Access.permits?('human', 'read', path: messages)
    refute Policy::Access.permits?('marlow', 'read', path: messages)
  end

  def test_a_hidden_room_is_excluded_from_search()
    write_room('secret', owner: 'marlow', involved: ['marlow'])

    refute Policy::Access.search?(@wren.name, @project)
    assert search?(@project)
  end

  private

  def read?(path)
    permits?(@marlow.name, 'read', path: path)
  end

  def write?(path)
    permits?(@marlow.name, 'write', path: path)
  end

  def search?(path)
    Policy::Access.search?(@marlow.name, path)
  end

  def execute?(command, base_dir: nil)
    permits?(@marlow.name, 'execute', command: command, base_dir: base_dir)
  end

  def permits?(name, kind, path: nil, command: nil, base_dir: nil)
    Policy::Access.permits?(name, kind, path: path, command: command, base_dir: base_dir)
  end
end
