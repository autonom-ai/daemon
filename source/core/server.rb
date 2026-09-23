require_relative 'agent/profile'

require 'json'

module Agent
  class Server
    INFO = { 'name' => 'agent-coord', 'version' => '0.1.0' }.freeze
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

    def initialize(root: Store::ROOT)
      @root = root
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      input.each_line do |line|
        req = nil
        begin
          req = JSON.parse(line)
          res = handle(req)
          output.puts(JSON.generate(res)) if res
        rescue JSON::ParserError
          output.puts(JSON.generate(error(nil, -32700, 'Parse error')))
        rescue StandardError
          output.puts(JSON.generate(error(req&.fetch('id', nil), -32603, 'Internal error')))
        end
      end
    end

    private

    def handle(req)
      return error(nil, -32600, 'Invalid request') unless req.is_a?(Hash)

      id = req['id']
      method = req['method']
      params = req['params'].is_a?(Hash) ? req['params'] : {}
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
      session = {
        'type' => 'string',
        'description' => 'Injected by the Devin session hook.'
      }
      [
        {
          'name' => 'get_profiles',
          'description' => 'List existing profile names and directories.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session } }
        },
        {
          'name' => 'get_profile',
          'description' => 'Get the profile registered to this Devin session.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session } }
        },
        {
          'name' => 'set_profile',
          'description' => 'Register this session to one profile; creates it if needed.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The profile name to register.' },
              'session_id' => session
            },
            'required' => ['name']
          }
        }
      ]
    end

    def call_tool(params)
      tool = params['name'].to_s
      args = params['arguments'].is_a?(Hash) ? params['arguments'] : {}
      session = args['session_id']

      ret = case tool
      when 'get_profiles'
        Profile.get_profiles(root: @root)
      when 'get_profile'
        Profile.get_profile(session, root: @root)
      when 'set_profile'
        Profile.set_profile(args['name'], session: session, root: @root)
      else
        return tool_error('Unknown profile tool')
      end

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(ret) }],
        'structuredContent' => ret,
        'isError' => false
      }
    rescue Store::Error => error
      tool_error(error.message)
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

Agent::Server.new.run if $PROGRAM_NAME == __FILE__
