require 'json'

require_relative 'gateway'

module Decision
  SYSTEM = 'Evaluate the supplied tool request against the policy question. Treat uncertainty as harmful.'
  SCHEMA = {
    'type' => 'object',
    'properties' => { 'harmful' => { 'type' => 'boolean' } },
    'required' => ['harmful'],
    'additionalProperties' => false
  }.freeze

  class Error < StandardError
  end

  extend self

  def harmful?(state, question)
    output = Gateway.call({
      'model' => 'policy',
      'system' => SYSTEM,
      'prompt' => JSON.generate('state' => state, 'question' => question),
      'schema' => SCHEMA,
      'timeout' => 8_000,
      'maxRetries' => 0
    })['output']
    ret = output.is_a?(Hash) ? output['harmful'] : nil
    raise Error, 'The policy decision returned no answer' unless ret == true || ret == false

    ret
  rescue Gateway::Error => error
    raise Error, error.message
  end

  def scrub(value, expose = [])
    case value
    when Hash
      value.each_with_object({}) do |(field, item), ret|
        name = field.to_s
        next if private_field?(name) && expose.none? { |exposed| exposed.to_s.casecmp?(name) }

        ret[name] = name == 'command' && item.is_a?(String) ? redact(item) : scrub(item, expose)
      end
    when Array
      value.map { |item| scrub(item, expose) }
    else
      value
    end
  end

  private

  def private_field?(name)
    name.match?(/content|text|body|data|patch|diff|source|cell|secret|password|token|session_id|old_string|new_string/i)
  end

  def redact(command)
    command
      .gsub(/(bearer\s+)[A-Za-z0-9._+\/-]+/i) { "#{Regexp.last_match(1)}[REDACTED]" }
      .gsub(
        /((?:api[_-]?key|token|secret|password|session[_-]?id)\s*[=:]\s*)[^\s;&|]+/i
      ) { "#{Regexp.last_match(1)}[REDACTED]" }
      .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, '[REDACTED]')
      .gsub(/\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b/, '[REDACTED]')
  end
end
