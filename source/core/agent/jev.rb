require_relative 'store'

require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

module Agent
  module Jev
    ENDPOINT = URI('https://api.openjev.sh/v1/systemone')
    THRESHOLD = 0.5

    class Error < StandardError
    end

    extend self

    def openjev_api_key
      key = ENV['OPENJEV_API_KEY']
      return key unless key.nil? || key.empty?

      file = File.join(Store::ROOT, '.env')
      return nil unless File.file?(file)

      File.foreach(file) do |line|
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

    def harmful?(tool:, input:, name:)
      key = openjev_api_key
      raise Error, 'OpenJEV API key is unavailable' if key.nil? || key.empty?

      req = Net::HTTP::Post.new(ENDPOINT)
      req['Authorization'] = "Bearer #{key}"
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(payload(tool, input, name))
      res = Net::HTTP.start(
        ENDPOINT.hostname,
        ENDPOINT.port,
        use_ssl: true,
        open_timeout: 2,
        read_timeout: 6,
        write_timeout: 2,
      ) { |http| http.request(req) }
      raise Error, 'OpenJEV policy check returned an error' unless res.is_a?(Net::HTTPSuccess)

      score = JSON.parse(res.body).dig('answers', 'harmful', 'noul')
      raise Error, 'OpenJEV policy check returned no decision' unless score.is_a?(Numeric) && score.finite?

      score >= THRESHOLD
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, 'OpenJEV policy check is unavailable'
    end

    def payload(tool, input, name)
      {
        'model' => 'openjev',
        'state' => {
          'tool_name' => tool.to_s,
          'tool_input' => scrub(input),
          'profile_name' => name,
          'policy' => [
            'get_profiles lists profile names and paths only.',
            'The first set_profile claim is trusted; later changes are disallowed.',
            'The session map is private. Only the mapped profile may be read or changed.',
            'Deleting home or core and bypassing restrictions are harmful.'
          ]
        },
        'questions' => {
          'harmful' => {
            'type' => 'noul',
            'instructions' => [
              'Does this request access another profile or the session map?',
              'Does it delete a protected directory or evade restrictions, including through redirection?',
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

    def redact(cmd)
      cmd
        .gsub(/(bearer\s+)[A-Za-z0-9._~+\/-]+/i) { "#{Regexp.last_match(1)}[REDACTED]" }
        .gsub(
          /((?:api[_-]?key|token|secret|password|session[_-]?id)\s*[=:]\s*)[^\s;&|]+/i
        ) { "#{Regexp.last_match(1)}[REDACTED]" }
        .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, '[REDACTED]')
        .gsub(/\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b/, '[REDACTED]')
    end
  end
end
