require_relative '../decision'
require_relative '../mcp/protocol'
require_relative '../profile_store'
require_relative 'format'

require 'json'

module Policy
  class Server
    INFO = { 'name' => 'autonom-policy', 'version' => '0.1.0' }.freeze

    include MCP::Protocol

    def initialize(decision: Decision)
      @decision = decision
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      input.each_line do |line|
        respond(parse(line), output)
      end
    end

    private

    def tools
      session_schema = { 'type' => 'string', 'description' => 'Injected by the Devin session hook.' }
      [
        {
          'name' => 'check_policy',
          'description' => 'Check a tool request against the primary policy and the caller\'s profile policy.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'tool_name' => { 'type' => 'string' },
              'tool_input' => { 'type' => 'object' },
              'session_id' => session_schema
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
  end
end

Policy::Server.new.run if $PROGRAM_NAME == __FILE__
