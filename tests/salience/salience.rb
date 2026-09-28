require 'minitest/autorun'

require_relative 'common'
require_relative '../source/salience/salience'

class SalienceTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    write_room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_unread_lines_reports_undrained_signals()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))
    Bus.dm(@marlow, 'dm text', from: @wren)
    Bus.post(room('general'), 'room text', from: @wren)

    lines = Salience.unread_lines(Bus.unread(@marlow))

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #room:general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, Bus.pings_by_profile(@marlow).unread(@marlow).length
  end

  def test_a_direct_message_outranks_room_traffic()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))
    Bus.dm(@marlow, 'dm text', from: @wren)
    Bus.post(room('general'), 'room text', from: @wren)

    focus = Salience.focus(Salience.impulses(Bus.unread(@marlow)))

    assert_equal 'Respond', focus.kind
    assert focus.required?
    assert_includes focus.context, 'ping text'
    assert_includes focus.context, 'dm text'
    assert_equal 'Action', focus.channel
  end

  def test_room_traffic_alone_is_a_coordinate_impulse()
    Bus.post(room('general'), 'anyone around?', from: @wren)

    focus = Salience.focus(Salience.impulses(Bus.unread(@marlow)))

    assert_equal 'Coordinate', focus.kind
    refute focus.required?
  end

  def test_stop_text_is_one_complete_message()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))

    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'call wait_for_message on the room'
  end

  def test_stop_text_is_nil_when_nothing_is_waiting()
    assert_nil Salience.stop_text(@marlow)
  end
end
