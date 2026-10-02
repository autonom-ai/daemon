require 'json'
require 'open3'

module Decision
  ENTRY = File.expand_path('../dist/ai/decision.js', __dir__)
  TIMEOUT = 12

  class Error < StandardError
  end

  extend self

  def harmful?(state, question)
    raise Error, 'The AI decision bridge has not been built' unless File.file?(ENTRY)

    Open3.popen3('node', ENTRY) do |stdin, stdout, _stderr, waiter|
      stdin.write(JSON.generate('state' => state, 'question' => question))
      stdin.close
      unless waiter.join(TIMEOUT)
        Process.kill('TERM', waiter.pid)
        raise Error, 'The policy decision timed out'
      end
      raise Error, 'The policy decision is unavailable' unless waiter.value.success?

      parsed = JSON.parse(stdout.read)
      ret = parsed.is_a?(Hash) ? parsed['harmful'] : nil
      raise Error, 'The policy decision returned no answer' unless ret == true || ret == false

      ret
    end
  rescue JSON::ParserError, IOError, SystemCallError
    raise Error, 'The policy decision is unavailable'
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
