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

  def test_identity_and_memory_are_sourced_from_the_profile()
    File.write(File.join(@marlow.directory, 'identity.md'), "---\ndisplayName: Marlow\n---\n\nI read the kill columns.\n")
    FileUtils.mkdir_p(File.join(@marlow.directory, 'memories'))
    File.write(File.join(@marlow.directory, 'memories', 'memory.md'), "# marlow - memory\n\n## Now\n\nChecking the pricer.\n")

    assert_equal 'Marlow', @marlow.identity.display_name
    assert_includes @marlow.identity.get()['personality'], 'I read the kill columns.'
    assert_includes @marlow.memory.get(), 'Checking the pricer.'
  end

  def test_heartbeat_is_zero_until_stamped()
    assert_equal 0, @marlow.heartbeat

    @marlow.touch_heartbeat()

    assert @marlow.heartbeat.positive?
  end
end
