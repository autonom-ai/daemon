require 'minitest/autorun'

require_relative '../support'

class RoomTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    ProfileStore.register_profile('marlow', 'session-1')
    ProfileStore.register_profile('wren', 'session-2')
    ProfileStore.register_profile('quill', 'session-3')
    write_room('general', owner: 'marlow')
    @room = room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_a_room_is_a_folder_with_a_stream_policy_and_membership()
    assert File.directory?(@room.directory)
    assert File.file?(@room.messages_path)
    assert File.file?(@room.policy_path)
    assert File.file?(@room.profiles_path)
    assert_equal 'marlow', @room.owner
    assert_equal 'room:general', @room.stream
  end

  def test_the_original_owner_and_human_administer()
    assert @room.original_owner?('marlow')
    assert @room.original_owner?('human')
    refute @room.original_owner?('wren')
    assert @room.administrator?('marlow')
    assert @room.administrator?('human')
    refute @room.administrator?('wren')
  end

  def test_admins_are_added_and_removed()
    @room.add_admin('wren')

    assert @room.admin?('wren')
    assert @room.administrator?('wren')

    @room.remove_admin('wren')

    refute @room.admin?('wren')
  end

  def test_involved_nil_is_everyone_and_a_list_is_exactly_those()
    assert @room.involved?('quill')

    @room.set_involved(%w[marlow wren])

    assert @room.involved?('marlow')
    assert @room.involved?('wren')
    refute @room.involved?('quill')
    assert @room.visible?('marlow')
    refute @room.visible?('quill')
  end

  def test_an_unreadable_membership_file_fails_closed()
    File.write(@room.profiles_path, 'not json')

    refute @room.involved?('wren')
    refute @room.visible?('wren')
    assert @room.original_owner?('human')
  end
end
