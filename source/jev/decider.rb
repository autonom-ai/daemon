require 'json'
require 'uri'

module JEV
  # Decider: a local model behind LM Studio's OpenAI-compatible server, asked in
  # the plain layout it was trained on. The answer is the letter at the prompt's
  # answer slot, so a question goes one per request, and only noul questions are
  # answered — a choice or score question needs a readout this transport does not
  # expose.
  module Decider
    ENDPOINT = URI('http://127.0.0.1:1234/v1/completions')
    MODEL = 'decider-4b-v2'
    LABEL = 'Decider'
    TIMEOUTS = { open_timeout: 2, read_timeout: 15, write_timeout: 2 }.freeze

    extend self

    def decide(state, questions)
      questions.each_with_object({}) do |(id, question), ret|
        ret[id] = answer(state, question)
      end
    end

    def payload(state, question)
      criteria = question['criteria'] || {}
      {
        'model' => MODEL,
        'prompt' => [
          'Context:',
          JSON.generate(state),
          '',
          "Question: #{question.fetch('instructions')}",
          'Options:',
          "(A) no: #{criteria['false']}",
          "(B) yes: #{criteria['true']}",
          'Answer: ('
        ].join("\n"),
        'max_tokens' => 1,
        'temperature' => 0
      }
    end

    private

    def answer(state, question)
      raise Error, "#{LABEL} answers noul questions only" unless question['type'] == 'noul'

      response = Common.post_json(ENDPOINT, payload(state, question), timeouts: TIMEOUTS)
      choices = response['choices']
      choice = choices.first if choices.is_a?(Array)
      letter = choice['text'].to_s.strip if choice.is_a?(Hash)

      case letter
      when 'A' then { 'type' => 'noul', 'noul' => 0.0 }
      when 'B' then { 'type' => 'noul', 'noul' => 1.0 }
      else raise Error, "#{LABEL} returned no decision"
      end
    end
  end
end
