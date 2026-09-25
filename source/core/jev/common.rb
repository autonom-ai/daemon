require_relative '../agent/store'

require 'json'
require 'net/http'
require 'openssl'
require 'timeout'

module JEV
  # What the backends share: the key lookup, the JSON POST, and the redaction a
  # request runs through before it leaves the machine.
  module Common
    TIMEOUTS = { open_timeout: 2, read_timeout: 6, write_timeout: 2 }.freeze

    extend self

    def api_key(name)
      key = ENV[name]
      return key unless key.nil? || key.empty?

      dotenv(name)
    end

    def post_json(endpoint, body, api_key: nil, timeouts: TIMEOUTS)
      request = Net::HTTP::Post.new(endpoint)
      request['Authorization'] = "Bearer #{api_key}" if api_key
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
      response = Net::HTTP.start(
        endpoint.hostname,
        endpoint.port,
        use_ssl: endpoint.scheme == 'https',
        **timeouts
      ) { |http| http.request(request) }
      raise Error, "#{endpoint.hostname} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      raise Error, "#{endpoint.hostname} returned no object" unless parsed.is_a?(Hash)

      parsed
    rescue Error
      raise
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "#{endpoint.hostname} is unavailable"
    end

    # A tool input as a backend should see it: content-bearing fields dropped,
    # credentials in a command redacted.
    def scrub(value, key = nil)
      case value
      when Hash
        value.each_with_object({}) do |(field, item), ret|
          next if field.to_s.match?(
            /content|text|body|data|patch|diff|source|cell|secret|password|token|session_id|old_string|new_string/i
          )

          ret[field.to_s] = scrub(item, field.to_s)
        end
      when Array
        value.map { |item| scrub(item) }
      when String
        key == 'command' ? redact(value) : value
      else
        value
      end
    end

    private

    # The clone's .env is where a key lives when the environment does not carry it.
    def dotenv(name)
      file = File.join(Agent::Store::ROOT, '.env')
      return nil unless File.file?(file)

      File.foreach(file) do |line|
        match = /\A\s*#{Regexp.escape(name)}\s*=\s*(.*?)\s*\z/.match(line)
        next unless match

        value = match[1]
        if value.length >= 2 && ["'", '"'].include?(value[0]) && value[-1] == value[0]
          value = value[1...-1]
        else
          value = value.sub(/\s+#.*\z/, '').strip
        end
        return value unless value.empty?
      end

      nil
    rescue SystemCallError
      nil
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
end
