require 'minitest/autorun'

require_relative 'common'
require_relative '../source/salience/salience'

class SalienceTest < Minitest::Test
  include CoreTest

  def setup()
    setup_bus()
    @marlow = @bus.register('session-1', 'marlow')
    @wren = @bus.register('session-2', 'wren')
  end

  def teardown()
    teardown_bus()
  end

  def test_unread_lines_reports_undrained_signals()
    @marlow.inbox.ping('ping text', from: @wren, room: @bus.room('general'))
    @marlow.inbox.dm('dm text', from: @wren)
    @bus.room('general').post('room text', from: @wren)

    lines = Salience.unread_lines(@marlow.unread)

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, @marlow.inbox.unread_pings.length
  end

  def test_a_direct_message_outranks_room_traffic()
    @marlow.inbox.ping('ping text', from: @wren, room: @bus.room('general'))
    @marlow.inbox.dm('dm text', from: @wren)
    @bus.room('general').post('room text', from: @wren)

    focus = Salience.focus(Salience.impulses(@marlow.unread))

    assert_equal 'Respond', focus.kind
    assert focus.required?
    assert_includes focus.context, 'ping text'
    assert_includes focus.context, 'dm text'
    assert_equal 'Action', focus.channel
  end

  def test_room_traffic_alone_is_a_coordinate_impulse()
    @bus.room('general').post('anyone around?', from: @wren)

    focus = Salience.focus(Salience.impulses(@marlow.unread))

    assert_equal 'Coordinate', focus.kind
    refute focus.required?
  end

  def test_stop_text_is_one_complete_message()
    @marlow.inbox.ping('ping text', from: @wren, room: @bus.room('general'))

    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'call wait_for_message on the room'
  end

  def test_stop_text_is_nil_when_nothing_is_waiting()
    assert_nil Salience.stop_text(@marlow)
  end
end
