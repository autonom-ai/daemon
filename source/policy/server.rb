require 'json'

require_relative '../decision'
require_relative '../profile_store'
require_relative 'access'
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
          'description' => 'Check a tool request against the primary policy and the caller\'s active secondary policy.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'tool_name' => { 'type' => 'string' },
              'tool_input' => { 'type' => 'object' },
              'secondary' => { 'type' => ['string', 'null'], 'description' => 'Secondary policy.yml path.' },
              'session_id' => session
            },
            'required' => ['tool_name']
          }
        },
        {
          'name' => 'set_secondary_policy',
          'description' => 'Create or replace a secondary policy.yml at an existing directory path.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'path' => { 'type' => 'string', 'description' => 'Path to the secondary policy.yml.' },
              'policy' => { 'type' => ['object', 'string'] },
              'session_id' => session
            },
            'required' => %w[path policy]
          }
        },
        {
          'name' => 'list_secondary_policies',
          'description' => 'List accessible secondary policy.yml files beneath a directory.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'directory' => { 'type' => 'string' },
              'session_id' => session
            },
            'required' => ['directory']
          }
        },
        {
          'name' => 'remove_secondary_policy',
          'description' => 'Remove an accessible secondary policy.yml file.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'path' => { 'type' => 'string', 'description' => 'Path to the secondary policy.yml.' },
              'session_id' => session
            },
            'required' => ['path']
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
      when 'set_secondary_policy'
        authorize_write(args)
        Policy.set_secondary(args['path'], args['policy'])
      when 'list_secondary_policies'
        name = ProfileStore.profile_by_session(args['session_id'])&.name
        Policy.secondary_policies(args['directory']) { |path| Policy::Access.permits?(name, 'read', path: path) }
      when 'remove_secondary_policy'
        authorize_write(args)
        Policy.remove_secondary(args['path'])
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

    def check_policy(args)
      profile = ProfileStore.profile_by_session(args['session_id'])
      policies = [Policy.workspace]
      unless args['secondary'].to_s.empty?
        unless Policy::Access.permits?(profile&.name, 'read', path: args['secondary'])
          raise Policy::Error, 'Secondary policy access is denied'
        end

        policies << Policy.secondary(args['secondary'])
      end
      denied, reason = Policy.decide(
        policies,
        {
          'tool_name' => args['tool_name'].to_s,
          'tool_input' => args['tool_input'].is_a?(Hash) ? args['tool_input'] : {},
          'profile_name' => profile&.name
        },
        decision: @decision
      )
      { 'denied' => denied, 'reason' => reason, 'secondary' => args['secondary'] }
    end

    def authorize_write(args)
      name = ProfileStore.profile_by_session(args['session_id'])&.name
      raise Policy::Error, 'Secondary policy changes are denied' unless Policy::Access.permits?(
        name,
        'write',
        path: args['path']
      )
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
