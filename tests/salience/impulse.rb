require 'minitest/autorun'

require_relative '../support'
require_relative '../../source/salience/impulse'

class ImpulseTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
  end

  def teardown()
    teardown_core()
  end

  def test_only_respond_is_required()
    assert Salience::Impulse.new('Respond', 'x').required?
    refute Salience::Impulse.new('Report', 'x').required?
  end

  def test_an_unknown_kind_raises()
    assert_raises(ArgumentError) { Salience::Impulse.new('Nope', 'x') }
  end

  def test_origin_defaults_to_unread()
    assert_equal 'unread', Salience::Impulse.new('Continue', 'x').origin
    assert_equal 'activity', Salience::Impulse.new('Continue', 'x', origin: 'activity').origin
  end

  def test_context_is_clipped()
    impulse = Salience::Impulse.new('Explore', 'x' * 5000)

    assert_equal Salience::Impulse::MAX_CONTEXT, impulse.context.length
  end
end
