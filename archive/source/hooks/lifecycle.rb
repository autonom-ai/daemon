require_relative '../profile_store'
require_relative '../salience'
require_relative '../coord/bus'
require_relative 'responses'

module Hooks
  module Lifecycle
    include Responses
    extend self

    # SessionStart - hand the tab its own context: who it is, who else is here,
    # and what the room has been saying.
    def session_start(event)
      profile = ProfileStore.profile_by_session(event['session_id'])
      context('SessionStart', Salience.briefing(profile))
    end

    # UserPromptSubmit - a nudge, not a delivery: cursors stay where the agent
    # left them, so the same traffic is still waiting in read_messages.
    def prompt_submit(event)
      profile = ProfileStore.profile_by_session(event['session_id'])
      return nil unless profile

      lines = ["You are #{profile.name}."]
      lines.concat(Salience.unread_lines(Bus.unread(profile)))
      context('UserPromptSubmit', lines.join("\n"))
    end

    def post_tool_use(event)
      profile = ProfileStore.profile_by_session(event['session_id'])
      return nil unless profile

      pings = Bus.pings_by_profile(profile).unread(profile)
      return nil if pings.empty?

      context('PostToolUse', Salience.ping_lines(pings).join("\n"))
    end

    def stop(event)
      profile = ProfileStore.profile_by_session(event['session_id'])
      return nil unless profile

      reason = Salience.stop_text(profile)
      return nil unless reason

      block(reason)
    end
  end
end
