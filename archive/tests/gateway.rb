require 'minitest/autorun'

require_relative 'support'
require_relative '../source/gateway'

class GatewayTest < Minitest::Test
  include MockProvider

  def test_the_gateway_returns_a_structured_decision()
    request = with_provider('{"harmful":false}') do
      ret = Gateway.call({
        'model' => 'policy',
        'prompt' => 'Is it harmful?',
        'schema' => {
          'type' => 'object',
          'properties' => { 'harmful' => { 'type' => 'boolean' } },
          'required' => ['harmful'],
          'additionalProperties' => false
        }
      })
      assert_equal false, ret.dig('output', 'harmful')
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
end
