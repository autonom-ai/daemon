require 'json'
require 'minitest/autorun'

require_relative 'support'
require_relative '../source/decision'

class DecisionTest < Minitest::Test
  include MockProvider

  def test_a_decision_returns_a_boolean()
    with_provider('{"harmful":false}') do
      refute Decision.harmful?({ 'tool_name' => 'read' }, 'Is it harmful?')
    end
  end

  def test_the_bridge_rejects_an_invalid_structured_decision()
    with_provider('{"harmful":"unknown"}') do
      assert_raises(Decision::Error) { Decision.harmful?({}, 'Is it harmful?') }
    end
  end

  def test_the_bridge_fails_when_the_provider_is_unreachable()
    with_env(
      'AUTONOM_OPENROUTER_BASE_URL' => 'http://127.0.0.1:1/v1',
      'OPENROUTER_API_KEY' => 'test-key'
    ) do
      assert_raises(Decision::Error) { Decision.harmful?({}, 'Is it harmful?') }
    end
  end

  def test_scrub_drops_content_and_redacts_credentials()
    scrubbed = Decision.scrub(
      'command' => 'OPENROUTER_API_KEY=secret-value echo 123e4567-e89b-12d3-a456-426614174000',
      'session_id' => 'private-session-id',
      'content' => 'private content',
      'patch' => 'private patch content',
      'file_path' => '/tmp/note.md'
    )
    serialized = JSON.generate(scrubbed)

    refute_includes serialized, 'secret-value'
    refute_includes serialized, 'private content'
    refute_includes serialized, 'private patch content'
    refute_includes serialized, 'private-session-id'
    refute_includes serialized, '123e4567-e89b-12d3-a456-426614174000'
    assert_includes serialized, '[REDACTED]'
    assert_includes serialized, '/tmp/note.md'
  end

  def test_scrub_keeps_only_fields_a_rule_exposes()
    scrubbed = Decision.scrub(
      {
        'text' => 'message text',
        'patch' => 'private patch content',
        'nested' => { 'text' => 'inner', 'token' => 'abc' }
      },
      ['text']
    )

    assert_equal 'message text', scrubbed['text']
    assert_equal 'inner', scrubbed.dig('nested', 'text')
    refute scrubbed.key?('patch')
    refute scrubbed['nested'].key?('token')
  end
end
