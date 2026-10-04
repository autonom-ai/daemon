require 'minitest/autorun'

require_relative 'support'

class ProfileTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
  end

  def teardown()
    teardown_core()
  end

  def test_identity_is_sourced_from_the_profile()
    File.write(
      File.join(@marlow.directory, 'identity.md'),
      "---\ndisplayName: Marlow\n---\n\nI read the kill columns.\n"
    )

    assert_equal 'Marlow', @marlow.identity.display_name
    assert_includes @marlow.identity.get()['personality'], 'I read the kill columns.'
  end

  def test_the_posted_policy_is_persisted()
    write_room('general')
    assert_nil @marlow.policy

    @marlow.policy = room('general').policy_path

    assert_equal room('general').policy_path, @marlow.policy
  end

  def test_the_profile_policy_is_workspace_specific()
    write_room('general')
    @marlow.policy = room('general').policy_path
    ENV['DEVIN_PROJECT_DIR'] = File.join(@project, 'another-workspace')

    assert_nil @marlow.policy
    @marlow.policy = File.join(@project, 'another-workspace', 'policy.yml')
    ENV['DEVIN_PROJECT_DIR'] = @project
    assert_equal room('general').policy_path, @marlow.policy
  end

  def test_the_profile_policy_must_be_a_policy_file()
    assert_raises(ProfileStore::Error) { @marlow.policy = 'notes.md' }
    assert_raises(ProfileStore::Error) { @marlow.policy = nil }
  end

  def test_online_reports_the_mapped_sessions_lock()
    refute @marlow.online?

    with_online_session('session-1') { assert @marlow.online? }
  end
end
