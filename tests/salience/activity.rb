require 'minitest/autorun'

require_relative '../support'
require_relative '../../source/salience/activity'

class ActivityTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
  end

  def teardown()
    teardown_core()
  end

  def test_a_call_refills_its_drive_and_drains_the_others()
    8.times { record('edit', { 'file_path' => 'source/x.rb' }) }
    state = Salience::Activity.state(@marlow, now: Time.at(5000))

    assert_equal 1.0, state['drives']['work'].round(2)
    assert_operator state['drives']['social'], :<, 0.2
    assert_equal 8, state['calls']
    assert_equal 'edit', state['last']['tool']
    assert_equal 'source/x.rb', state['last']['detail']
  end

  def test_drives_decay_with_time()
    record('mcp__autonom-coord-mcp__send_message', {}, now: Time.at(5000))
    later = Salience::Activity.state(@marlow, now: Time.at(5000 + 1800))

    # One social half-life is 900s, so 1800s later the full drive is a quarter.
    assert_in_delta 0.25, later['drives']['social'], 0.01
  end

  def test_an_unknown_tool_is_neutral()
    record('ask_user_question', {})
    state = Salience::Activity.state(@marlow, now: Time.at(5000))

    assert_equal [0.75, 0.75, 0.75], state['drives'].values
    assert_equal 1, state['calls']
  end

  def test_coord_and_foreign_mcp_tools_land_in_social_and_explore()
    assert_equal 'social', Salience::Activity.category('mcp__autonom-coord-mcp__send_message')
    assert_equal 'explore', Salience::Activity.category('mcp__openings-mcp__search_jobs')
    assert_equal 'work', Salience::Activity.category('exec')
    assert_nil Salience::Activity.category('ask_user_question')
  end

  def test_starved_names_the_weakest_drive_and_rotates_with_the_work()
    8.times { record('edit', {}) }
    assert_equal 'social', Salience::Activity.starved(Salience::Activity.state(@marlow, now: Time.at(5000)))

    # Reporting drains explore while it feeds social, so the next nudge is
    # the lead worth chasing.
    2.times { record('mcp__autonom-coord-mcp__send_message', {}) }
    assert_equal 'explore', Salience::Activity.starved(Salience::Activity.state(@marlow, now: Time.at(5000)))
  end

  def test_a_fed_profile_has_no_starved_drive()
    File.write(File.join(@marlow.directory, 'activity.json'), JSON.generate(
      'ts' => 5_000_000,
      'calls' => 3,
      'drives' => { 'social' => 0.9, 'work' => 0.9, 'explore' => 0.9 },
      'last' => nil
    ))

    state = Salience::Activity.state(@marlow, now: Time.at(5000))

    assert_nil Salience::Activity.starved(state)
  end

  private

  def record(tool, input = {}, now: Time.at(5000))
    Salience::Activity.record(@marlow, tool, input, now: now)
  end
end
