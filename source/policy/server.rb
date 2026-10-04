require 'json'

require_relative '../decision'
require_relative '../profile_store'
require_relative 'format'

module Policy
  class Server
    INFO = { 'name' => 'autonom-policy', 'version' => '0.1.0' }.freeze
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

    def initialize(decision: Decision)
      @decision = decision
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      input.each_line do |line|
        request = parse(line)
        response = request ? handle(request) : error(nil, -32700, 'Parse error')
        output.puts(JSON.generate(response)) if response
      rescue StandardError
        id = request.is_a?(Hash) ? request['id'] : nil
        output.puts(JSON.generate(error(id, -32603, 'Internal error')))
      end
    end

    private

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def handle(request)
      return error(nil, -32600, 'Invalid request') unless request.is_a?(Hash)

      id = request['id']
      method = request['method']
      params = request['params'].is_a?(Hash) ? request['params'] : {}
      return nil if method == 'notifications/initialized' || method == 'notifications/cancelled'
      return error(id, -32600, 'Invalid request') unless method.is_a?(String)

      case method
      when 'initialize'
        protocol = params['protocolVersion']
        protocol = '2025-03-26' unless PROTOCOLS.include?(protocol)
        success(
          id,
          'protocolVersion' => protocol,
          'capabilities' => { 'tools' => { 'listChanged' => false } },
          'serverInfo' => INFO
        )
      when 'ping'
        success(id, {})
      when 'tools/list'
        success(id, 'tools' => tools)
      when 'tools/call'
        success(id, call_tool(params))
      else
        error(id, -32601, 'Method not found')
      end
    end

    def tools
      session = { 'type' => 'string', 'description' => 'Injected by the Devin session hook.' }
      [
        {
          'name' => 'check_policy',
          'description' => 'Check a tool request against the primary policy and the caller\'s profile policy.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'tool_name' => { 'type' => 'string' },
              'tool_input' => { 'type' => 'object' },
              'session_id' => session
            },
            'required' => ['tool_name']
          }
        }
      ]
    end

    def call_tool(params)
      tool = params['name'].to_s
      args = params['arguments'].is_a?(Hash) ? params['arguments'] : {}
      ret = case tool
      when 'check_policy'
        check_policy(args)
      else
        return tool_error('Unknown policy tool')
      end

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(ret) }],
        'isError' => false
      }
    rescue Decision::Error, Policy::Error, ProfileStore::Error => error
      tool_error(error.message)
    end

    # The profile's secondary policy is the room policy it last posted under;
    # the coordination server records it as `profile.policy`.
    def check_policy(args)
      profile = ProfileStore.profile_by_session(args['session_id'])
      denied, reason = Policy.decide(
        [Policy.workspace, Policy.load(profile&.policy)],
        {
          'tool_name' => args['tool_name'].to_s,
          'tool_input' => args['tool_input'].is_a?(Hash) ? args['tool_input'] : {},
          'profile_name' => profile&.name
        },
        decision: @decision
      )
      { 'denied' => denied, 'reason' => reason, 'secondary' => profile&.policy }
    end

    def tool_error(message)
      { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true }
    end

    def success(id, ret)
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => ret }
    end

    def error(id, code, message)
      { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } }
    end
  end
end

Policy::Server.new.run if $PROGRAM_NAME == __FILE__
