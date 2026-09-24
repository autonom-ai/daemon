require_relative 'agent/jev'
require_relative 'agent/profile'

require 'json'

module Agent
  module Hooks
    SESSION_TOOLS = %w[
      mcp__agent-coord__get_profiles
      mcp__agent-coord__get_profile
      mcp__agent-coord__set_profile
      mcp__agent-coord__send_message
      mcp__agent-coord__read_messages
    ].freeze

    extend self

    def call(event, jev: Jev, root: Store::ROOT)
      case event['hook_event_name']
      when 'SessionStart'
        session_start(event, root: root)
      when 'PreToolUse'
        pre_tool_use(event, jev: jev, root: root)
      when 'PostToolUse'
        post_tool_use(event, root: root)
      end
    rescue Jev::Error
      block('OpenJEV policy check is unavailable; request blocked')
    rescue Store::Error
      case event['hook_event_name']
      when 'PreToolUse'
        block('Profile access could not be verified')
      when 'SessionStart'
        context_error
      end
    end

    private

    def session_start(event, root:)
      session = event['session_id']
      profile = Profile.get_profile(session, root: root)
      lines = []
      lines << "Your session ID is #{session}. Tell the user what it is." if session

      if profile
        lines << "Your profile is #{profile['name']} at #{profile['directory']}."
      else
        lines << 'No profile is registered yet. Use get_profiles and set_profile with your assigned name.'
        lines << 'If you were not given a profile name, ask the user before registering.'
      end

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'SessionStart',
          'additionalContext' => lines.join("\n")
        }
      }
    end

    def pre_tool_use(event, jev:, root:)
      tool = event['tool_name'].to_s
      input = event['tool_input'].is_a?(Hash) ? event['tool_input'] : {}
      session = event['session_id']
      reason = denial(tool, input, session, root: root)
      return block(reason) if reason

      profile = Profile.get_profile(session, root: root)
      if jev.harmful?(tool: tool, input: input, name: profile&.fetch('name', nil))
        return block('OpenJEV policy check denied this request')
      end

      return nil unless SESSION_TOOLS.include?(tool) && valid_session?(session)

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'PreToolUse',
          'updatedInput' => { 'session_id' => session }
        }
      }
    end

    # Every tool call is a chance to deliver what the agent has not seen: an
    # unread ping rides back as context, and reading it advances the cursor so
    # it is delivered exactly once. A failure here must never break the tool.
    def post_tool_use(event, root:)
      session = event['session_id']
      return nil unless valid_session?(session)

      profile = Profile.get_profile(session, root: root)
      return nil unless profile

      pings = Profile.read_pings(profile['name'], root: root)
      return nil if pings.empty?

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'PostToolUse',
          'additionalContext' => ping_context(pings)
        }
      }
    end

    def ping_context(pings)
      lines = ["Unread pings (#{pings.length}) — reply in the room when you get a turn:"]
      pings.each do |ping|
        room = ping['room'] ? " in ##{ping['room']}" : ''
        lines << "[#{Time.at(ping['ts'].to_i / 1000.0).strftime('%H:%M:%S')}] #{ping['from']}#{room}: #{ping['text']}"
      end
      lines.join("\n")
    end

    def denial(tool, input, session, root:)
      case tool
      when 'mcp__agent-coord__get_profile'
        'A Devin session ID is required' unless valid_session?(session)
      when 'mcp__agent-coord__set_profile'
        return 'A Devin session ID is required' unless valid_session?(session)
        return 'A session profile cannot be changed after registration' unless Profile.permissions.can_set_profile?(
          input['name'],
          session: session,
          root: root
        )
      when 'read', 'notebook_read'
        paths(tool, input).each do |path|
          return 'Access to this profile or protected file is blocked' unless Profile.permissions.can_read?(
            path,
            session: session,
            root: root,
            dir: project_dir
          )
        end
      when 'grep'
        return 'Access to this profile or protected file is blocked' unless Profile.permissions.can_search?(
          input['path'] || project_dir,
          session: session,
          root: root,
          dir: project_dir
        )
      when 'glob'
        return 'Access to this profile or protected file is blocked' unless Profile.permissions.can_glob?(
          input['pattern'],
          path: input['path'] || project_dir,
          session: session,
          root: root,
          dir: project_dir
        )
      when 'write', 'edit', 'notebook_edit', 'apply_patch'
        paths(tool, input).each do |path|
          return 'Access to this profile or protected file is blocked' unless Profile.permissions.can_write?(
            path,
            session: session,
            root: root,
            dir: project_dir
          )
        end
      when 'exec'
        return 'Execution targets a protected profile or directory' unless Profile.permissions.can_exec?(
          input['command'],
          session: session,
          root: root,
          dir: input['cwd'] || input['working_directory'] || project_dir
        )
      end

      nil
    end

    def paths(tool, input)
      return patch_paths(input['patch']) if tool == 'apply_patch'

      [input['file_path'], input['notebook_path'], input['path']].compact
    end

    def patch_paths(patch)
      return [] unless patch.is_a?(String)

      patch.scan(/^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$/).flatten
    end

    def project_dir
      ENV['DEVIN_PROJECT_DIR'] || Dir.pwd
    end

    def valid_session?(session)
      session.is_a?(String) && !session.empty?
    end

    def block(reason)
      { 'decision' => 'block', 'reason' => reason }
    end

    def context_error
      {
        'hookSpecificOutput' => {
          'hookEventName' => 'SessionStart',
          'additionalContext' => 'Profile context could not be loaded; ask the user before registering a profile.'
        }
      }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ret = Agent::Hooks.call(JSON.parse(STDIN.read))
    puts JSON.generate(ret) if ret
  rescue JSON::ParserError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook payload was invalid')
  rescue StandardError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook could not verify this request')
  end
end
