require 'minitest/autorun'

require_relative 'common'

class ProfileStoreTest < Minitest::Test
  include CoreTest

  def setup()
    setup_bus()
  end

  def teardown()
    teardown_bus()
  end

  def test_registration_creates_a_profile_and_keeps_its_canonical_name()
    record = @store.register('session-1', 'New_Agent')

    assert_equal 'new_agent', record.name
    assert File.directory?(File.join(@root, 'agents', 'new_agent', 'memories'))
    assert File.file?(File.join(@root, 'agents', 'new_agent', 'identity.md'))
    assert_equal record, @store.session('session-1')
  end

  def test_an_existing_profile_keeps_its_canonical_case()
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow', 'memories'))

    assert_equal 'Marlow', @store.register('session-1', 'mArLoW').name
    assert_equal 'Marlow', @store.record('marlow').name
  end

  def test_a_session_profile_cannot_be_reassigned()
    @store.register('session-1', 'marlow')

    assert_raises(ProfileStore::Error) { @store.register('session-1', 'wren') }
  end

  def test_records_list_every_profile()
    FileUtils.mkdir_p(File.join(@root, 'agents', 'Marlow'))
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren'))

    assert_equal %w[Marlow wren], @store.records.map(&:name)
  end
end
