require_relative 'agent/jev'
require_relative 'agent/profile'

require 'json'

module Agent
  module Hooks
    CORE_TOOLS = %w[
      mcp__agent-coord__get_profiles
      mcp__agent-coord__get_profile
      mcp__agent-coord__set_profile
    ].freeze

    extend self

    def call(event, jev: Jev, root: Store::ROOT)
      case event['hook_event_name']
      when 'SessionStart'
        session_start(event, root: root)
      when 'PreToolUse'
        pre_tool_use(event, jev: jev, root: root)
      end
    rescue Jev::Error
      block('OpenJEV policy check is unavailable; request blocked')
    rescue Store::Error
      event['hook_event_name'] == 'PreToolUse' ? block('Profile access could not be verified') : profile_context_error
    end

    private

    def session_start(event, root:)
      session_id = event['session_id']
      profile = Profile.get_profile(session_id, root: root)
      lines = []
      lines << "Your session ID is #{session_id}. Tell the user what it is." if session_id

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
      tool_name = event['tool_name'].to_s
      tool_input = event['tool_input'].is_a?(Hash) ? event['tool_input'] : {}
      session_id = event['session_id']
      denial = local_denial(tool_name, tool_input, session_id, root: root)
      return block(denial) if denial

      profile = Profile.get_profile(session_id, root: root)
      if jev.harmful?(tool_name: tool_name, tool_input: tool_input, profile_name: profile&.fetch('name', nil))
        return block('OpenJEV policy check denied this request')
      end

      return nil unless CORE_TOOLS.include?(tool_name) && valid_session_id?(session_id)

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'PreToolUse',
          'updatedInput' => { 'session_id' => session_id }
        }
      }
    end

    def local_denial(tool_name, tool_input, session_id, root:)
      case tool_name
      when 'mcp__agent-coord__get_profile'
        'A Devin session ID is required' unless valid_session_id?(session_id)
      when 'mcp__agent-coord__set_profile'
        return 'A Devin session ID is required' unless valid_session_id?(session_id)
        return 'A session profile cannot be changed after registration' unless Profile.can_set_profile?(
          tool_input['name'],
          session_id: session_id,
          root: root
        )
      when 'read', 'notebook_read'
        paths_for(tool_name, tool_input).each do |path|
          return 'Access to this profile or protected file is blocked' unless Profile.can_read?(
            path,
            session_id: session_id,
            root: root,
            working_directory: project_directory
          )
        end
      when 'grep'
        return 'Access to this profile or protected file is blocked' unless Profile.can_search?(
          tool_input['path'] || project_directory,
          session_id: session_id,
          root: root,
          working_directory: project_directory
        )
      when 'glob'
        return 'Access to this profile or protected file is blocked' unless Profile.can_glob?(
          tool_input['pattern'],
          path: tool_input['path'] || project_directory,
          session_id: session_id,
          root: root,
          working_directory: project_directory
        )
      when 'write', 'edit', 'notebook_edit', 'apply_patch'
        paths_for(tool_name, tool_input).each do |path|
          return 'Access to this profile or protected file is blocked' unless Profile.can_write?(
            path,
            session_id: session_id,
            root: root,
            working_directory: project_directory
          )
        end
      when 'exec'
        return 'Execution targets a protected profile or directory' unless Profile.can_exec?(
          tool_input['command'],
          session_id: session_id,
          root: root,
          working_directory: tool_input['cwd'] || tool_input['working_directory'] || project_directory
        )
      end

      nil
    end

    def paths_for(tool_name, tool_input)
      return patch_paths(tool_input['patch']) if tool_name == 'apply_patch'

      [tool_input['file_path'], tool_input['notebook_path'], tool_input['path']].compact
    end

    def patch_paths(patch)
      return [] unless patch.is_a?(String)

      patch.scan(/^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$/).flatten
    end

    def project_directory
      ENV['DEVIN_PROJECT_DIR'] || Dir.pwd
    end

    def valid_session_id?(session_id)
      session_id.is_a?(String) && !session_id.empty?
    end

    def block(reason)
      { 'decision' => 'block', 'reason' => reason }
    end

    def profile_context_error
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
    hook_output = Agent::Hooks.call(JSON.parse(STDIN.read))
    puts JSON.generate(hook_output) if hook_output
  rescue JSON::ParserError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook payload was invalid')
  rescue StandardError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook could not verify this request')
  end
end
