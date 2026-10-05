require_relative '../decision'
require_relative '../profile_store'
require_relative '../policy/access'
require_relative '../policy/format'
require_relative '../workspace'
require_relative '../coord/bus'
require_relative 'responses'

module Hooks
  module ToolGate
    SESSION_TOOLS = %w[
      mcp__autonom-coord__get_profiles
      mcp__autonom-coord__get_profile_status
      mcp__autonom-coord__set_profile
      mcp__autonom-coord__post_message
      mcp__autonom-coord__read_messages
      mcp__autonom-coord__wait_for_message
      mcp__autonom-coord__list_rooms
      mcp__autonom-coord__create_room
      mcp__autonom-coord__delete_room
      mcp__autonom-coord__set_room_involved
      mcp__autonom-coord__add_room_admin
      mcp__autonom-coord__remove_room_admin
      mcp__autonom-policy__check_policy
    ].freeze

    DENIED = 'Access to this profile or protected file is blocked'

    include Responses
    extend self

    def pre_tool_use(event, decision: Decision)
      tool = event['tool_name'].to_s
      input = event['tool_input'].is_a?(Hash) ? event['tool_input'] : {}
      session_id = event['session_id']
      profile = ProfileStore.profile_by_session(session_id)
      reason = denial(tool, input, session_id, profile)
      return block(reason) if reason

      if profile && !Bus.pings_by_profile(profile).unread(profile).empty? &&
          !(tool == 'mcp__autonom-coord__read_messages' && input['source'].to_s == 'pings')
        return block('You have unread pings - read them first: call read_messages with source "pings"')
      end

      denied, reason = Policy.decide(
        [Policy.workspace, Policy.load(profile&.policy)],
        {
          'tool_name' => tool,
          'tool_input' => input,
          'profile_name' => profile && profile.name
        },
        decision: decision
      )
      return block(reason || 'The policy check denied this request') if denied

      return nil unless SESSION_TOOLS.include?(tool) && !session_id.to_s.empty?

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'PreToolUse',
          'updatedInput' => { 'session_id' => session_id.to_s }
        }
      }
    end

    private

    def denial(tool, input, session_id, profile)
      profile_name = profile && profile.name
      case tool
      when 'mcp__autonom-coord__get_profile_status'
        'A Devin session ID is required' if session_id.to_s.empty?
      when 'mcp__autonom-coord__set_profile'
        return 'A Devin session ID is required' if session_id.to_s.empty?

        claimed_name = input['name'].to_s
        return 'A valid profile name is required' unless ProfileStore.valid_name?(claimed_name)
        return 'The human profile is reserved' if claimed_name.casecmp?(ProfileStore::HUMAN_NAME)
        return 'A session profile cannot be changed after registration' if
          profile_name && !profile_name.casecmp?(claimed_name)
      when 'read', 'notebook_read'
        input_paths(tool, input).each do |file_path|
          return DENIED unless Policy::Access.permits?(profile_name, 'read', path: file_path)
        end
      when 'grep'
        return DENIED unless Policy::Access.search?(profile_name, input['path'] || Workspace.project_dir)
      when 'glob'
        return DENIED unless Policy::Access.glob?(
          profile_name,
          input['pattern'],
          input['path'] || Workspace.project_dir
        )
      when 'write', 'edit', 'notebook_edit', 'apply_patch'
        input_paths(tool, input).each do |file_path|
          return DENIED unless Policy::Access.permits?(profile_name, 'write', path: file_path)
        end
      when 'exec'
        return 'Execution targets a protected profile or directory' unless Policy::Access.permits?(
          profile_name,
          'execute',
          command: input['command'],
          base_dir: input['cwd'] || input['working_directory']
        )
      end

      nil
    end

    def input_paths(tool, input)
      return patch_file_paths(input['patch']) if tool == 'apply_patch'

      [input['file_path'], input['notebook_path'], input['path']].compact
    end

    def patch_file_paths(patch)
      return [] unless patch.is_a?(String)

      patch.scan(/^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$/).flatten
    end
  end
end
