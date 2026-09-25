require 'uri'

module JEV
  # TypeSafe's Jev, reached through OpenRouter's Decisions API: billed per input
  # token to the account behind the key. The pinned version is deliberate, so a
  # policy gate does not shift under us.
  module TypeSafe
    ENDPOINT = URI('https://openrouter.ai/api/alpha/decisions')
    KEY_ENV = 'OPENROUTER_API_KEY'
    MODEL = 'typesafe/jev-1.13'
    LABEL = 'TypeSafe'

    extend self

    def decide(state, questions)
      key = Common.api_key(KEY_ENV)
      raise Error, "#{LABEL} API key is unavailable" if key.nil? || key.empty?

      response = Common.post_json(ENDPOINT, payload(state, questions), api_key: key)
      response.fetch('answers') { raise Error, "#{LABEL} returned no answers" }
    end

    def payload(state, questions)
      { 'model' => MODEL, 'state' => state, 'questions' => questions }
    end
  end
end
