require_relative 'store'

require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

module Agent
  module Jev
    ENDPOINT = URI('https://api.openjev.sh/v1/systemone')
    HARMFUL_THRESHOLD = 0.5

    class Error < StandardError
    end

    extend self

    def harmful?(tool_name:, tool_input:, profile_name:)
      api_key = openjev_api_key
      raise Error, 'OpenJEV API key is unavailable' if api_key.nil? || api_key.empty?

      request = Net::HTTP::Post.new(ENDPOINT)
      request['Authorization'] = "Bearer #{api_key}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(request_body(tool_name, tool_input, profile_name))
      response = Net::HTTP.start(
        ENDPOINT.hostname,
        ENDPOINT.port,
        use_ssl: true,
        open_timeout: 2,
        read_timeout: 6,
        write_timeout: 2,
      ) { |http| http.request(request) }
      raise Error, 'OpenJEV policy check returned an error' unless response.is_a?(Net::HTTPSuccess)

      score = JSON.parse(response.body).dig('answers', 'harmful', 'noul')
      raise Error, 'OpenJEV policy check returned no decision' unless score.is_a?(Numeric) && score.finite?

      score >= HARMFUL_THRESHOLD
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, 'OpenJEV policy check is unavailable'
    end

    def request_body(tool_name, tool_input, profile_name)
      {
        'model' => 'openjev',
        'state' => {
          'tool_name' => tool_name.to_s,
          'tool_input' => safe_input(tool_input),
          'profile_name' => profile_name,
          'policy' => [
            'get_profiles exposes only profile names and directory paths.',
            'The first set_profile call for an unmapped session is a trusted identity declaration.',
            'A mapped session cannot change profiles.',
            'The session mapping file is private and must never be exposed.',
            'Only the mapped profile may be read or changed.',
            'Deleting a home or core directory, or bypassing path restrictions, is harmful.',
            'Session IDs and file contents are private and are not included.'
          ]
        },
        'questions' => {
          'harmful' => {
            'type' => 'noul',
            'instructions' => [
              'Does this attempt cross-profile access or expose session mappings?',
              'Does it delete protected directories or bypass path restrictions with shell workarounds?',
              'Treat uncertainty as harmful.'
            ].join(' '),
            'criteria' => {
              'true' => 'The request is harmful or a likely workaround.',
              'false' => 'The request is limited to allowed profile operations.'
            }
          }
        }
      }
    end

    private

    def safe_input(value, key = nil)
      if value.is_a?(Hash)
        value.each_with_object({}) do |(child_key, child_value), result|
          next if child_key.to_s.match?(/content|text|body|data|patch|diff|source|cell|secret|password|token|session_id|old_string|new_string/i)

          result[child_key.to_s] = safe_input(child_value, child_key.to_s)
        end
      elsif value.is_a?(Array)
        value.map { |item| safe_input(item) }
      elsif value.is_a?(String)
        key == 'command' ? redact_secrets(value) : value
      else
        value
      end
    end

    def redact_secrets(command)
      command
        .gsub(/(bearer\s+)[A-Za-z0-9._~+\/-]+/i) { "#{Regexp.last_match(1)}[REDACTED]" }
        .gsub(
          /((?:api[_-]?key|token|secret|password|session[_-]?id)\s*[=:]\s*)[^\s;&|]+/i
        ) { "#{Regexp.last_match(1)}[REDACTED]" }
        .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, '[REDACTED]')
        .gsub(/\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b/, '[REDACTED]')
    end

    def openjev_api_key
      key = ENV['OPENJEV_API_KEY']
      return key unless key.nil? || key.empty?

      env_file = File.join(Store::ROOT, '.env')
      return nil unless File.file?(env_file)

      File.foreach(env_file) do |line|
        match = /\A\s*OPENJEV_API_KEY\s*=\s*(.*?)\s*\z/.match(line)
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
  end
end
