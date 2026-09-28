require 'minitest/autorun'

require_relative 'support'
require_relative '../source/policy'

class PolicyTest < Minitest::Test
  include CoreTest

  class FakeJev
    attr_reader :calls

    def initialize(harmful: false)
      @harmful = harmful
      @calls = 0
    end

    def decide(_state, _questions)
      @calls += 1
      { 'harmful' => { 'noul' => @harmful ? 1.0 : 0.0 } }
    end
  end

  def setup()
    setup_core()
    @jev = FakeJev.new
  end

  def teardown()
    teardown_core()
  end

  def test_a_deny_rule_matches_the_tool_and_an_input_field()
    rules = load(<<~'YAML')
      rules:
        - match:
            tool: exec
            command: 'rm\s+-rf'
          action: deny
          reason: blocked
    YAML

    denied, reason = Policy.decide([rules], request('exec', 'command' => 'rm -rf /'), jev: @jev)

    assert denied
    assert_equal 'blocked', reason
    assert_equal 0, @jev.calls
  end

  def test_a_screen_rule_asks_the_backend()
    rules = load(<<~'YAML')
      rules:
        - action: screen
          reason: screened
          question:
            type: noul
            instructions: is it bad
            criteria:
              true: yes
              false: no
    YAML

    denied, = Policy.decide([rules], request('exec'), jev: @jev)

    refute denied
    assert_equal 1, @jev.calls
  end

  def test_a_later_allow_cannot_outrank_an_earlier_deny()
    master = load(<<~'YAML')
      rules:
        - match: { tool: exec }
          action: deny
          reason: master
    YAML
    room = load(<<~'YAML')
      rules:
        - match: { tool: exec }
          action: allow
    YAML

    denied, reason = Policy.decide([master, room], request('exec'), jev: @jev)

    assert denied
    assert_equal 'master', reason
  end

  def test_a_rule_that_matches_nothing_allows()
    rules = load(<<~'YAML')
      rules:
        - match: { tool: read }
          action: deny
          reason: no
    YAML

    denied, = Policy.decide([rules], request('exec'), jev: @jev)

    refute denied
    assert_equal 0, @jev.calls
  end

  def test_the_master_template_loads_and_screens()
    assert Policy.master.any?

    denied, = Policy.decide([Policy.master], request('exec', 'command' => 'git status'), jev: @jev)

    refute denied
    assert_equal 1, @jev.calls
  end

  def test_a_malformed_policy_raises()
    assert_raises(Policy::Error) { load('rules: {nope}') }
  end

  private

  def load(body)
    path = File.join(@project, 'policy.yml')
    File.write(path, body)
    Policy.load(path)
  end

  def request(tool, input = {})
    { 'tool_name' => tool, 'tool_input' => input, 'profile_name' => 'marlow' }
  end
end
