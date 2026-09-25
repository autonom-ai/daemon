require 'json'
require 'minitest/autorun'

require_relative '../source/core/jev'

class JevTest < Minitest::Test
  def test_backends_carry_their_own_transport_and_model
    assert_equal 'openjev', JEV::OpenJEV::MODEL
    assert_equal 'api.openjev.sh', JEV::OpenJEV::ENDPOINT.hostname
    assert_equal 'OPENJEV_API_KEY', JEV::OpenJEV::KEY_ENV

    assert_equal 'typesafe/jev-1.13', JEV::TypeSafe::MODEL
    assert_equal 'openrouter.ai', JEV::TypeSafe::ENDPOINT.hostname
    assert_equal 'OPENROUTER_API_KEY', JEV::TypeSafe::KEY_ENV

    assert_equal 'decider-4b-v2', JEV::Decider::MODEL
    assert_equal '127.0.0.1', JEV::Decider::ENDPOINT.hostname
  end

  def test_system_one_backends_ask_the_same_question
    state = { 'tool_name' => 'read' }
    questions = { 'harmful' => { 'type' => 'noul', 'instructions' => 'Is it harmful?' } }

    openjev = JEV::OpenJEV.payload(state, questions)
    typesafe = JEV::TypeSafe.payload(state, questions)

    assert_equal openjev['state'], typesafe['state']
    assert_equal openjev['questions'], typesafe['questions']
    assert_equal 'typesafe/jev-1.13', typesafe['model']
  end

  def test_the_backend_is_selectable_by_name
    assert_equal JEV::OpenJEV, JEV.backend

    JEV.backend = 'Decider'
    assert_equal JEV::Decider, JEV.backend

    JEV.backend = :typesafe
    assert_equal JEV::TypeSafe, JEV.backend

    assert_raises(JEV::Error) { JEV.backend = 'nope' }
    assert_equal JEV::TypeSafe, JEV.backend
  ensure
    JEV.backend = 'openjev'
  end

  def test_decide_goes_through_the_selected_backend
    JEV.backend = 'decider'

    error = assert_raises(JEV::Error) do
      JEV.decide({}, 'route' => { 'type' => 'choice', 'criteria' => { 'a' => nil, 'b' => nil } })
    end

    assert_equal 'Decider answers noul questions only', error.message
  ensure
    JEV.backend = 'openjev'
  end

  def test_decider_renders_the_plain_layout_it_was_trained_on
    payload = JEV::Decider.payload(
      { 'tool_name' => 'exec', 'tool_input' => { 'command' => 'rm -rf /' } },
      {
        'type' => 'noul',
        'instructions' => 'Is it harmful?',
        'criteria' => { 'true' => 'harmful', 'false' => 'fine' }
      }
    )

    assert_equal 'decider-4b-v2', payload['model']
    assert_equal 1, payload['max_tokens']
    assert_equal 0, payload['temperature']
    assert_includes payload['prompt'], "Context:\n{\"tool_name\":\"exec\""
    assert_includes payload['prompt'], 'Question: Is it harmful?'
    assert_includes payload['prompt'], "(A) no: fine\n(B) yes: harmful\nAnswer: ("
  end

  def test_scrub_drops_content_and_redacts_credentials
    scrubbed = JEV::Common.scrub(
      'command' => 'OPENJEV_API_KEY=secret-value echo 123e4567-e89b-12d3-a456-426614174000',
      'session_id' => 'private-session-id',
      'content' => 'private memory content',
      'patch' => 'private patch content',
      'file_path' => '/tmp/note.md'
    )
    serialized = JSON.generate(scrubbed)

    refute_includes serialized, 'secret-value'
    refute_includes serialized, 'private memory content'
    refute_includes serialized, 'private patch content'
    refute_includes serialized, 'private-session-id'
    refute_includes serialized, '123e4567-e89b-12d3-a456-426614174000'
    assert_includes serialized, '[REDACTED]'
    assert_includes serialized, '/tmp/note.md'
  end
end
