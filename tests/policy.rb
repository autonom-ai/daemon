require 'minitest/autorun'

require_relative 'support'
require_relative '../source/policy'

class PolicyTest < Minitest::Test
  include CoreTest

  class FakeDecision
    attr_reader :calls, :state

    def initialize(harmful: false)
      @harmful = harmful
      @calls = 0
    end

    def harmful?(state, _question)
      @calls += 1
      @state = state
      @harmful
    end
  end

  def setup()
    setup_core()
    @decision = FakeDecision.new
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

    denied, reason = Policy.decide([rules], request('exec', 'command' => 'rm -rf /'), decision: @decision)

    assert denied
    assert_equal 'blocked', reason
    assert_equal 0, @decision.calls
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

    denied, = Policy.decide([rules], request('exec'), decision: @decision)

    refute denied
    assert_equal 1, @decision.calls
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

    denied, reason = Policy.decide([workspace, room], request('exec'), decision: @decision)

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

    denied, = Policy.decide([rules], request('exec'), decision: @decision)

    refute denied
    assert_equal 0, @decision.calls
  end

  def test_the_required_workspace_policy_loads_and_screens()
    assert Policy.workspace.rules.any?
    assert Policy.workspace.guard?('codebase', 'quill')
    refute Policy.workspace.guard?('codebase', 'sable')

    denied, = Policy.decide([Policy.workspace], request('exec', 'command' => 'git status'), decision: @decision)

    refute denied
    assert_equal 1, @decision.calls
  end

  def test_the_workspace_file_controls_the_policy()
    FileUtils.mkdir_p(File.dirname(Workspace.policy_path))
    File.write(Workspace.policy_path, "rules: []\n")

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

    denied, = Policy.decide([rules], request('exec'), decision: @decision)

    refute denied

    denied, reason = Policy.decide([rules], request('exec', {}, 'wren'), decision: @decision)

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

  def test_a_screen_judges_only_the_fields_a_rule_exposes()
    policy = load(<<~'YAML')
      rules:
        - action: screen
          expose: [text]
          question:
            type: noul
            instructions: is it bad
            criteria:
              true: yes
              false: no
    YAML

    Policy.decide([policy], request('send_message', 'text' => 'sekrit', 'room' => 'general'), decision: @decision)

    assert_equal 'sekrit', @decision.state.dig('tool_input', 'text')
    assert_equal 'general', @decision.state.dig('tool_input', 'room')
  end

  def test_a_screen_without_expose_never_sees_text()
    policy = load(<<~'YAML')
      rules:
        - action: screen
          question:
            type: noul
            instructions: is it bad
            criteria:
              true: yes
              false: no
    YAML

    Policy.decide([policy], request('send_message', 'text' => 'sekrit', 'room' => 'general'), decision: @decision)

    refute @decision.state['tool_input'].key?('text')
    assert_equal 'general', @decision.state.dig('tool_input', 'room')
  end

  def test_expose_must_be_a_list()
    assert_raises(Policy::Error) do
      load("rules:\n  - action: deny\n    expose: text\n")
    end
  end

  def test_an_unknown_guard_raises()
    assert_raises(Policy::Error) { load("access:\n  - guard: nope\n") }
  end

  def test_a_malformed_policy_raises()
    assert_raises(Policy::Error) { load('rules: {nope}') }
  end

  def test_secondary_policies_are_managed_at_their_existing_paths()
    write_room('general')
    path = room('general').policy_path
    saved = Policy.set_secondary(path, 'rules' => [{ 'action' => 'deny', 'reason' => 'room' }])

    assert_equal path, saved['path']
    assert_equal [path], Policy.secondary_policies(Workspace.rooms_dir).map { |entry| entry['path'] }
    assert_equal 1, Policy.secondary(path).rules.length
    assert_equal({ 'path' => path, 'removed' => true }, Policy.remove_secondary(path))
    assert_nil Policy.secondary(path)
  end

  def test_secondary_policy_paths_cannot_replace_primary_or_follow_symlinks()
    write_room('general')
    target = File.join(@project, 'target.yml')
    File.write(target, "rules: []\n")
    link = File.join(@project, 'policy.yml')
    File.symlink(target, link)

    assert_raises(Policy::Error) { Policy.set_secondary(Workspace.policy_path, 'rules' => []) }
    assert_raises(Policy::Error) { Policy.set_secondary(link, 'rules' => []) }
  end

  def test_the_workspace_policy_is_required_without_template_fallback()
    FileUtils.mkdir_p(File.join(@root, 'templates'))
    FileUtils.cp(Workspace.policy_path, File.join(@root, 'templates', 'policy.yml'))
    File.unlink(Workspace.policy_path)

    assert_raises(Policy::Error) { Policy.workspace }
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
