require 'minitest/autorun'

require_relative 'common'

class ProfileStoreTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
  end

  def teardown()
    teardown_core()
  end

  def test_registration_creates_a_profile_and_keeps_its_canonical_name()
    profile = ProfileStore.register_profile('New_Agent', 'session-1')

    assert_equal 'new_agent', profile.name
    assert File.directory?(File.join(@root, 'agents', 'new_agent', 'memories'))
    assert File.file?(File.join(@root, 'agents', 'new_agent', 'identity.md'))
    assert_equal profile.directory, ProfileStore.profile_by_session('session-1').directory
  end

  def test_an_existing_profile_keeps_its_canonical_case()
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow', 'memories'))

    assert_equal 'Marlow', ProfileStore.register_profile('mArLoW', 'session-1').name
    assert_equal 'Marlow', ProfileStore.profile_by_name('marlow').name
  end

  def test_a_session_profile_cannot_be_reassigned()
    ProfileStore.register_profile('marlow', 'session-1')

    assert_raises(ProfileStore::Error) { ProfileStore.register_profile('wren', 'session-1') }
  end

  def test_profiles_are_listed_and_looked_up_by_name()
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow'))
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren'))

    assert_equal %w[Marlow wren], ProfileStore.profiles.map(&:name)
    assert_equal 'Marlow', ProfileStore.profile_by_name('marlow').name
    assert_nil ProfileStore.profile_by_name('nobody')
  end
end
