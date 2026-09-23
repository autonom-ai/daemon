require 'json'
require 'minitest/autorun'

require_relative '../source/core/agent/jev'

class JevTest < Minitest::Test
  def test_request_omits_session_id_and_file_contents
    body = Agent::Jev.payload(
      'exec',
      {
        'command' => 'OPENJEV_API_KEY=secret-value echo 123e4567-e89b-12d3-a456-426614174000',
        'session_id' => 'private-session-id',
        'content' => 'private memory content',
        'patch' => 'private patch content'
      },
      'marlow'
    )
    serialized = JSON.generate(body)

    refute_includes serialized, 'secret-value'
    refute_includes serialized, 'private memory content'
    refute_includes serialized, 'private patch content'
    refute_includes serialized, 'private-session-id'
    refute_includes serialized, '123e4567-e89b-12d3-a456-426614174000'
    assert_includes serialized, '[REDACTED]'
  end
end
