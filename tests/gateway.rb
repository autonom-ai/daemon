require 'json'
require 'minitest/autorun'
require 'socket'

require_relative '../source/decision'
require_relative '../source/gateway'

class GatewayTest < Minitest::Test
  def test_the_gateway_returns_a_structured_decision()
    request = with_provider('{"harmful":false}') do
      refute Decision.harmful?({ 'tool_name' => 'read' }, 'Is it harmful?')
    end

    assert_equal 'openai/gpt-5-mini', request['model']
    assert_equal 'json_schema', request.dig('response_format', 'type')
  end

  def test_the_gateway_returns_unstructured_text()
    with_provider('plain answer') do
      ret = Gateway.call({ 'model' => 'openrouter/test-model', 'prompt' => 'Say hi' })
      assert_equal 'plain answer', ret['text']
    end
  end

  def test_the_gateway_accepts_messages()
    with_provider('plain answer') do
      ret = Gateway.call({
        'model' => 'openrouter/test-model',
        'messages' => [{ 'role' => 'user', 'content' => 'hi' }]
      })
      assert_equal 'plain answer', ret['text']
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

  private

  def with_env(overrides)
    previous = overrides.keys.to_h { |name| [name, ENV[name]] }
    overrides.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end

  def with_provider(content)
    server = TCPServer.new('127.0.0.1', 0)
    worker = Thread.new do
      socket = server.accept
      headers = []
      while (line = socket.gets) && line != "\r\n"
        headers << line
      end
      length = headers.find { |line| line.downcase.start_with?('content-length:') }.split(':', 2).last.to_i
      ret = JSON.parse(socket.read(length))
      body = JSON.generate(
        'id' => 'test-response',
        'object' => 'chat.completion',
        'created' => 0,
        'model' => 'test-model',
        'choices' => [{ 'index' => 0, 'message' => { 'role' => 'assistant', 'content' => content },
                        'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1, 'total_tokens' => 2 }
      )
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      ret
    ensure
      socket&.close
    end
    with_env(
      'AUTONOM_OPENROUTER_BASE_URL' => "http://127.0.0.1:#{server.addr[1]}/v1",
      'OPENROUTER_API_KEY' => 'test-key'
    ) do
      yield
      worker.value
    end
  ensure
    server&.close
    worker&.kill if worker&.alive?
  end
end
