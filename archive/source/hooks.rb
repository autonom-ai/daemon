require_relative 'hooks/lifecycle'
require_relative 'hooks/tool_gate'
require_relative 'hooks/responses'

require 'json'

module Hooks
  include Responses
  extend self

  def call(event, decision: Decision)
    case event['hook_event_name']
    when 'SessionStart'
      Lifecycle.session_start(event)
    when 'UserPromptSubmit'
      Lifecycle.prompt_submit(event)
    when 'PreToolUse'
      ToolGate.pre_tool_use(event, decision: decision)
    when 'PostToolUse'
      Lifecycle.post_tool_use(event)
    when 'Stop'
      Lifecycle.stop(event)
    end
  rescue Decision::Error, Policy::Error
    block('The policy check is unavailable; request blocked')
  rescue ProfileStore::Error, Bus::Error
    case event['hook_event_name']
    when 'PreToolUse'
      block('Profile access could not be verified')
    when 'SessionStart'
      context('SessionStart', 'Profile context could not be loaded; ask the user before registering a profile.')
    when 'Stop'
      block('Could not verify what is waiting; try again')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ret = Hooks.call(JSON.parse(STDIN.read))
    puts JSON.generate(ret) if ret
  rescue JSON::ParserError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook payload was invalid')
  rescue StandardError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook could not verify this request')
  end
end
