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
    workspace = load(<<~'YAML')
      rules:
        - match: { tool: exec }
          action: deny
          reason: workspace
    YAML
    room = load(<<~'YAML')
      rules:
        - match: { tool: exec }
          action: allow
    YAML

    denied, reason = Policy.decide([workspace, room], request('exec'), jev: @jev)

    assert denied
    assert_equal 'workspace', reason
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

  def test_the_default_template_loads_and_screens()
    assert Policy.workspace.rules.any?
    assert Policy.workspace.guard?('codebase', 'quill')
    refute Policy.workspace.guard?('codebase', 'sable')

    denied, = Policy.decide([Policy.workspace], request('exec', 'command' => 'git status'), jev: @jev)

    refute denied
    assert_equal 1, @jev.calls
  end

  def test_the_workspace_file_wins_over_the_template()
    File.write(Config.policy_path, "rules: []\n")
    Policy.reset!

    assert Policy.workspace.rules.empty?
    refute Policy.workspace.guard?('env', 'marlow')
  end

  def test_an_except_rule_does_not_apply_to_the_profile()
    rules = load(<<~'YAML')
      rules:
        - match: { tool: exec }
          action: deny
          reason: blocked
          except: [marlow]
    YAML

    denied, = Policy.decide([rules], request('exec'), jev: @jev)

    refute denied

    denied, reason = Policy.decide([rules], request('exec', {}, 'wren'), jev: @jev)

    assert denied
    assert_equal 'blocked', reason
  end

  def test_an_except_guard_does_not_apply_to_the_profile()
    policy = load(<<~'YAML')
      access:
        - guard: codebase
          except: [sable]
    YAML

    assert policy.guard?('codebase', 'quill')
    refute policy.guard?('codebase', 'Sable')
    refute policy.guard?('env', 'quill')
  end

  def test_an_unknown_guard_raises()
    assert_raises(Policy::Error) { load("access:\n  - guard: nope\n") }
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

  def request(tool, input = {}, profile = 'marlow')
    { 'tool_name' => tool, 'tool_input' => input, 'profile_name' => profile }
  end
end
