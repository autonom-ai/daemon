require_relative '../profile_store'
require_relative 'bus'

require 'json'

module Coord
  class Server
    INFO = { 'name' => 'autonom-coord', 'version' => '0.1.0' }.freeze
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    SOURCES = %w[room dms pings].freeze
    WAIT_SOURCES = %w[room dms].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    DEFAULT_WAIT = 30
    MAX_WAIT = 60
    ONLINE_MS = 30 * 60_000

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      write_lock = Mutex.new
      blocking = []
      input.each_line do |line|
        req = parse(line)
        # A blocking wait must not stall the requests behind it, so it runs on
        # its own thread. Everything else is answered in arrival order - a
        # client that sends set_profile then post_message must not see the two
        # race - and no worker outlives the process with its response unwritten.
        if waiting?(req)
          blocking << Thread.new { respond(req, output, write_lock) }
        else
          respond(req, output, write_lock)
        end
      end
      blocking.each(&:join)
    end

    private

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def waiting?(req)
      req.is_a?(Hash) && req['method'] == 'tools/call' && req.dig('params', 'name') == 'wait_for_message'
    end

    def respond(req, output, write_lock)
      res = req ? handle(req) : error(nil, -32700, 'Parse error')
      write_lock.synchronize { output.puts(JSON.generate(res)) } if res
    rescue StandardError
      id = req.is_a?(Hash) ? req['id'] : nil
      write_lock.synchronize { output.puts(JSON.generate(error(id, -32603, 'Internal error'))) }
    end

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
        },
        {
          'name' => 'post_message',
          'description' => 'Send a chat message. Pass `to` to DM one profile (the DM sits in their ' \
                           'dms and does not ping), or `room` for a room message. `room` is required ' \
                           'for room messages. `ping` names profiles to notify - each gets an unread ping, ' \
                           'delivered on their next tool call.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'text' => { 'type' => 'string', 'description' => 'The message text.' },
              'to' => { 'type' => 'string', 'description' => 'Profile name to DM; omit to post in a room.' },
              'room' => { 'type' => 'string', 'description' => 'Room to post in; ignored when `to` is set.' },
              'ping' => {
                'type' => 'array',
                'items' => { 'type' => 'string' },
                'description' => 'Profile names to ping.'
              },
              'session_id' => session
            },
            'required' => ['text']
          }
        },
        {
          'name' => 'read_messages',
          'description' => 'Read chat messages. `source` picks `room`, `dms`, or `pings`; `room` is required ' \
                           'for room reads. Reading a stream clears what it returns.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => SOURCES, 'description' => 'Which stream to read.' },
              'room' => { 'type' => 'string', 'description' => 'Room to read when source is room.' },
              'limit' => {
                'type' => 'integer',
                'description' => "Maximum entries to return (default #{DEFAULT_LIMIT})."
              },
              'session_id' => session
            }
          }
        },
        {
          'name' => 'wait_for_message',
          'description' => 'Block until something new arrives in `room` or `dms`; `room` is required for ' \
                           'room waits. Reading clears what it returns. A ping interrupts any wait and a DM ' \
                           'ends a dms wait; pings are not waitable.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => WAIT_SOURCES, 'description' => 'Which stream to wait on.' },
              'room' => { 'type' => 'string', 'description' => 'Room to wait on when source is room.' },
              'timeout' => {
                'type' => 'integer',
                'description' => "Seconds to wait (default #{DEFAULT_WAIT}, max #{MAX_WAIT})."
              },
              'session_id' => session
            }
          }
        },
        {
          'name' => 'list_rooms',
          'description' => 'List the workspace rooms: message count, unread count for this profile, and last activity.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session } }
        },
        {
          'name' => 'create_room',
          'description' => 'Create a workspace room. Names are case-insensitive and stored lowercase.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room name to create.' },
              'session_id' => session
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'delete_room',
          'description' => 'Delete a workspace room and its messages. Only the room\'s owner or admins may. ' \
                           'This cannot be undone.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room name to delete.' },
              'session_id' => session
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'set_room_involved',
          'description' => 'Set which profiles may use a room. Pass `null` (or omit) for everyone in the clone; ' \
                           'a list makes it private, and two names is a DM. The room\'s owner and admins may set this.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'involved' => {
                'type' => ['array', 'null'],
                'items' => { 'type' => 'string' },
                'description' => 'Profile names allowed in the room, or null for everyone.'
              },
              'session_id' => session
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'add_room_admin',
          'description' => 'Make a profile an admin of a room. Only the room\'s original owner may change its admins.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'profile' => { 'type' => 'string', 'description' => 'The profile to add as an admin.' },
              'session_id' => session
            },
            'required' => ['name', 'profile']
          }
        },
        {
          'name' => 'remove_room_admin',
          'description' => 'Remove a room admin. Only the room\'s original owner may change admins.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'profile' => { 'type' => 'string', 'description' => 'The admin to remove.' },
              'session_id' => session
            },
            'required' => ['name', 'profile']
          }
        },
        {
          'name' => 'get_heartbeat',
          'description' => 'Get a profile\'s heartbeat: when it last called a tool, and whether that is recent ' \
                           'enough to count as online. Every MCP call stamps the caller, so presence is a fact ' \
                           'about use.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'Profile name to read the heartbeat for.' },
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
        ProfileStore.profiles.map { |profile| profile_entry(profile) }
      when 'get_profile'
        profile_entry(ProfileStore.profile_by_session(session))
      when 'set_profile'
        profile_entry(ProfileStore.register_profile(args['name'], session))
      when 'post_message'
        post_message(args, session)
      when 'read_messages'
        read_messages(args, session)
      when 'wait_for_message'
        wait_for_message(args, session)
      when 'list_rooms'
        list_rooms(session)
      when 'create_room'
        create_room(args, session)
      when 'delete_room'
        delete_room(args, session)
      when 'set_room_involved'
        set_room_involved(args, session)
      when 'add_room_admin'
        add_room_admin(args, session)
      when 'remove_room_admin'
        remove_room_admin(args, session)
      when 'get_heartbeat'
        get_heartbeat(args)
      else
        return tool_error('Unknown profile tool')
      end

      # Update heartbeat.
      profile = ProfileStore.profile_by_session(session) rescue nil
      profile&.touch_heartbeat()

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(ret) }],
        'isError' => false
      }
    rescue ProfileStore::Error, Bus::Error => error
      tool_error(error.message)
    end

    def post_message(args, session)
      from = registered_profile(session)
      text = args['text'].to_s
      raise ProfileStore::Error, 'A message needs text' if text.strip.empty?

      targets = ping_targets(args['ping'], from)
      if args['to'].to_s.empty?
        room = room_named(args['room'], from)
        Bus.post(room, text, from: from)
        targets.each { |target| Bus.ping(target, text, from: from, room: room) }
        { 'result' => "Sent message to #{room.stream} with #{targets.length} pings" }
      else
        to = ProfileStore.profile_by_name(args['to'])
        raise ProfileStore::Error, "Unknown profile: #{args['to']}" unless to

        Bus.dm(to, text, from: from)
        targets.each { |target| Bus.ping(target, text, from: from) }
        { 'result' => "Sent message to #{to.name} with #{targets.length} pings" }
      end
    end

    def read_messages(args, session)
      profile = registered_profile(session)
      source, room = read_target(args, profile)
      read_stream(profile, source, room, limit(args))
    end

    # Wait behavior is somewhat complex but documented in Bus.
    def wait_for_message(args, session)
      profile = registered_profile(session)
      source, room = read_target(args, profile)
      raise ProfileStore::Error, 'Pings interrupt; they cannot be waited on' if source == 'pings'

      inbox = source == 'dms' ? Bus.dms_by_profile(profile) : room
      inbox.wait(profile, timeout: wait_timeout(args)) if inbox.unread(profile).empty?
      read_stream(profile, source, room, limit(args))
    end

    def list_rooms(session)
      profile = registered_profile(session)
      Bus.visible_rooms(profile).map { |room| room_entry(room, profile) }
    end

    def create_room(args, session)
      profile = registered_profile(session)
      room_entry(Bus.create_room(args['name'], owner: profile.name), profile)
    end

    def delete_room(args, session)
      profile = registered_profile(session)
      room = administered_room(args['name'], profile)
      Bus.delete_room(room.name)
      { 'result' => "Deleted room #{room.stream}" }
    end

    def set_room_involved(args, session)
      profile = registered_profile(session)
      room = administered_room(args['name'], profile)
      room.set_involved(involved_names(args['involved']))
      room_entry(room, profile)
    end

    def add_room_admin(args, session)
      profile = registered_profile(session)
      room = owned_room(args['name'], profile)
      room.add_admin(known_profile(args['profile']).name)
      room_entry(room, profile)
    end

    def remove_room_admin(args, session)
      profile = registered_profile(session)
      room = owned_room(args['name'], profile)
      room.remove_admin(known_profile(args['profile']).name)
      room_entry(room, profile)
    end

    def room_entry(room, profile)
      entries = room.messages
      {
        'name' => room.stream,
        'count' => entries.length,
        'unread' => room.unread(profile).length,
        'lastTs' => entries.last&.fetch('ts', nil)
      }
    end

    def get_heartbeat(args)
      profile = ProfileStore.profile_by_name(args['name'])
      raise ProfileStore::Error, "Unknown profile: #{args['name']}" unless profile

      heartbeat = profile.heartbeat
      {
        'name' => profile.name,
        'lastHeartbeat' => heartbeat,
        'online' => heartbeat.positive? && (Time.now.to_f * 1000).round - heartbeat < ONLINE_MS
      }
    end

    def profile_entry(profile)
      profile && { 'name' => profile.name, 'directory' => profile.directory }
    end

    def read_target(args, profile)
      source = args['source'].to_s
      source = 'room' if source.empty?
      raise ProfileStore::Error, "Unknown source: #{source}" unless SOURCES.include?(source)
      return [source, nil] unless source == 'room'

      [source, room_named(args['room'], profile)]
    end

    def room_named(name, profile)
      raise ProfileStore::Error, 'A room is required' if name.to_s.empty?

      room = Bus.room_by_name(name)
      raise ProfileStore::Error, "Unknown room: #{name}" unless room
      raise ProfileStore::Error, "Unknown room: #{name}" unless room.visible?(profile.name)

      room
    end

    # Admin operations report a room as unknown to anyone who cannot perform
    # them, so a private room's existence is not leaked.
    def administered_room(name, profile)
      room = Bus.room_by_name(name)
      raise ProfileStore::Error, "Unknown room: #{name}" unless room && room.administrator?(profile.name)

      room
    end

    def owned_room(name, profile)
      room = Bus.room_by_name(name)
      raise ProfileStore::Error, "Unknown room: #{name}" unless room && room.original_owner?(profile.name)

      room
    end

    def known_profile(name)
      profile = ProfileStore.profile_by_name(name)
      raise ProfileStore::Error, "Unknown profile: #{name}" unless profile

      profile
    end

    def involved_names(value)
      return nil if value.nil?
      raise ProfileStore::Error, 'Involved must be a list of profiles or null' unless value.is_a?(Array)

      value.map { |name| known_profile(name).name }
    end

    def read_stream(profile, source, room, limit)
      case source
      when 'dms'
        { 'source' => 'dms', 'messages' => Bus.dms_by_profile(profile).read(profile, limit: limit) }
      when 'pings'
        { 'source' => 'pings', 'messages' => Bus.pings_by_profile(profile).read(profile) }
      else
        {
          'source' => 'room',
          'room' => room.name,
          'messages' => room.read(profile, limit: limit)
        }
      end
    end

    def wait_timeout(args)
      value = args['timeout']
      value.is_a?(Integer) ? value.clamp(1, MAX_WAIT) : DEFAULT_WAIT
    end

    def registered_profile(session)
      profile = ProfileStore.profile_by_session(session)
      raise ProfileStore::Error, 'No profile is registered for this session; register one first' unless profile

      profile
    end

    def ping_targets(names, from)
      return [] unless names.is_a?(Array)

      targets = names.map do |name|
        target = ProfileStore.profile_by_name(name)
        raise ProfileStore::Error, "Unknown profile to ping: #{name}" unless target

        target
      end
      targets.uniq { |target| target.name.downcase }.reject { |target| target.name.casecmp?(from.name) }
    end

    def limit(args)
      value = args['limit']
      value.is_a?(Integer) ? value.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT
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

Coord::Server.new.run if $PROGRAM_NAME == __FILE__
