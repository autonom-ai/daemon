require 'uri'

module JEV
  # OpenJEV: an independent hosted service answering System One requests. It is
  # not TypeSafe's model, and it is not a promise about what happens to what you
  # send it.
  module OpenJEV
    ENDPOINT = URI('https://api.openjev.sh/v1/systemone')
    KEY_ENV = 'OPENJEV_API_KEY'
    MODEL = 'openjev'
    LABEL = 'OpenJEV'

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
