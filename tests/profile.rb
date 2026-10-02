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

  def test_the_last_posted_room_is_persisted()
    assert_nil @marlow.last_room

    assert_equal 'general', @marlow.focus_room('general')
    assert_equal 'general', @marlow.last_room
  end

  def test_last_room_focus_is_workspace_specific()
    @marlow.focus_room('general')
    ENV['DEVIN_PROJECT_DIR'] = File.join(@project, 'another-workspace')

    assert_nil @marlow.last_room
    @marlow.focus_room('other')
    ENV['DEVIN_PROJECT_DIR'] = @project
    assert_equal 'general', @marlow.last_room
  end

  def test_heartbeat_is_zero_until_stamped()
    assert_equal 0, @marlow.heartbeat

    @marlow.touch_heartbeat()

    assert @marlow.heartbeat.positive?
  end
end
