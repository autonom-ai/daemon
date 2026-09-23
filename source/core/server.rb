require_relative 'agent/profile'

require 'json'

module Agent
  class Server
    SERVER_INFO = { 'name' => 'agent-coord', 'version' => '0.1.0' }.freeze
    PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

    def initialize(root: Store::ROOT)
      @root = root
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      input.each_line do |line|
        request = nil
        begin
          request = JSON.parse(line)
          response = handle(request)
          output.puts(JSON.generate(response)) if response
        rescue JSON::ParserError
          output.puts(JSON.generate(error_response(nil, -32700, 'Parse error')))
        rescue StandardError
          output.puts(JSON.generate(error_response(request&.fetch('id', nil), -32603, 'Internal error')))
        end
      end
    end

    private

    def handle(request)
      return error_response(nil, -32600, 'Invalid request') unless request.is_a?(Hash)

      request_id = request['id']
      method = request['method']
      params = request['params'].is_a?(Hash) ? request['params'] : {}
      return nil if method == 'notifications/initialized' || method == 'notifications/cancelled'
      return error_response(request_id, -32600, 'Invalid request') unless method.is_a?(String)

      case method
      when 'initialize'
        protocol_version = params['protocolVersion']
        protocol_version = '2025-03-26' unless PROTOCOL_VERSIONS.include?(protocol_version)
        success_response(
          request_id,
          'protocolVersion' => protocol_version,
          'capabilities' => { 'tools' => { 'listChanged' => false } },
          'serverInfo' => SERVER_INFO
        )
      when 'ping'
        success_response(request_id, {})
      when 'tools/list'
        success_response(request_id, 'tools' => tools)
      when 'tools/call'
        success_response(request_id, call_tool(params))
      else
        error_response(request_id, -32601, 'Method not found')
      end
    end

    def tools
      session_id = {
        'type' => 'string',
        'description' => 'Injected by the Devin session hook.'
      }
      [
        {
          'name' => 'get_profiles',
          'description' => 'List existing profile names and directories.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session_id } }
        },
        {
          'name' => 'get_profile',
          'description' => 'Get the profile registered to this Devin session.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session_id } }
        },
        {
          'name' => 'set_profile',
          'description' => 'Register this session to one profile; creates it if needed.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The profile name to register.' },
              'session_id' => session_id
            },
            'required' => ['name']
          }
        }
      ]
    end

    def call_tool(params)
      name = params['name'].to_s
      arguments = params['arguments'].is_a?(Hash) ? params['arguments'] : {}
      session_id = arguments['session_id']

      data = case name
      when 'get_profiles'
        Profile.get_profiles(root: @root)
      when 'get_profile'
        Profile.get_profile(session_id, root: @root)
      when 'set_profile'
        Profile.set_profile(arguments['name'], session_id: session_id, root: @root)
      else
        return tool_error('Unknown profile tool')
      end

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(data) }],
        'structuredContent' => data,
        'isError' => false
      }
    rescue Store::Error => error
      tool_error(error.message)
    end

    def tool_error(message)
      { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true }
    end

    def success_response(request_id, result)
      { 'jsonrpc' => '2.0', 'id' => request_id, 'result' => result }
    end

    def error_response(request_id, code, message)
      { 'jsonrpc' => '2.0', 'id' => request_id, 'error' => { 'code' => code, 'message' => message } }
    end
  end
end

Agent::Server.new.run if $PROGRAM_NAME == __FILE__
