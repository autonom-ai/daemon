require_relative '../config'
require_relative '../profile_store'
require_relative 'bus'

require 'json'

module Coord
  # The MCP server: JSON-RPC over stdio, one bus per workspace.
  class Server
    INFO = { 'name' => 'autonom-coord-mcp', 'version' => '0.1.0' }.freeze
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    SOURCES = %w[room inbox pings].freeze
    WAIT_SOURCES = %w[room inbox].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    DEFAULT_WAIT = 30
    MAX_WAIT = 60
    ONLINE_MS = 30 * 60_000

    def initialize(bus)
      @bus = bus
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      write_lock = Mutex.new
      blocking = []
      input.each_line do |line|
        req = parse(line)
        # A blocking wait must not stall the requests behind it, so it runs on
        # its own thread. Everything else is answered in arrival order - a
        # client that sends set_profile then send_message must not see the two
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
          'name' => 'send_message',
          'description' => 'Send a chat message. Pass `to` to DM one profile (the DM sits in their ' \
                           'inbox and does not ping), or `room` for a room message (defaults to the ' \
                           'team room). `ping` names profiles to notify - each gets an unread ping, ' \
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
          'description' => 'Read chat messages. `source` picks the stream: `room` (a room, default the team ' \
                           'room), `inbox` (DMs), or `pings` (unread pings; reading clears them). Reading a ' \
                           'stream clears what it returns.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => SOURCES, 'description' => 'Which stream to read.' },
              'room' => { 'type' => 'string', 'description' => 'Room to read when source is room.' },
              'limit' => { 'type' => 'integer', 'description' => "Maximum entries to return (default #{DEFAULT_LIMIT})." },
              'session_id' => session
            }
          }
        },
        {
          'name' => 'wait_for_message',
          'description' => 'Block until something new arrives, then return it: `room` (a room, default the ' \
                           'team room) or `inbox` (DMs). Returns as soon as there is anything unread, and ' \
                           'empty when the timeout runs out. Reading clears what it returns. A ping ' \
                           'interrupts any wait and a DM ends an inbox wait; pings are not waitable.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => WAIT_SOURCES, 'description' => 'Which stream to wait on.' },
              'room' => { 'type' => 'string', 'description' => 'Room to wait on when source is room.' },
              'timeout' => { 'type' => 'integer', 'description' => "Seconds to wait (default #{DEFAULT_WAIT}, max #{MAX_WAIT})." },
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
        @bus.profiles.map { |profile| profile_entry(profile) }
      when 'get_profile'
        profile_entry(@bus.profile(session))
      when 'set_profile'
        profile_entry(@bus.register(session, args['name']))
      when 'send_message'
        send_message(args, session)
      when 'read_messages'
        read_messages(args, session)
      when 'wait_for_message'
        wait_for_message(args, session)
      when 'list_rooms'
        list_rooms(session)
      when 'get_heartbeat'
        get_heartbeat(args)
      else
        return tool_error('Unknown profile tool')
      end

      # Every call is a sign of life, stamped after the tool ran so a
      # registration counts as the caller's first heartbeat.
      stamp_heartbeat(session)

      {
        'content' => [{ 'type' => 'text', 'text' => JSON.generate(ret) }],
        'structuredContent' => ret,
        'isError' => false
      }
    rescue ProfileStore::Error, Bus::Error => error
      tool_error(error.message)
    end

    def send_message(args, session)
      from = registered_profile(session)
      text = args['text'].to_s
      raise ProfileStore::Error, 'A message needs text' if text.strip.empty?

      targets = ping_targets(args['ping'], from)
      if args['to'].to_s.empty?
        room = @bus.room(args['room'])
        entry = room.post(text, from: from)
        targets.each { |target| target.inbox.ping(text, from: from, room: room) }
        { 'room' => room.name, 'entry' => entry, 'pinged' => targets.map(&:name) }
      else
        to = @bus.profile_named(args['to'])
        raise ProfileStore::Error, "Unknown profile: #{args['to']}" unless to

        entry = to.inbox.dm(text, from: from)
        targets.each { |target| target.inbox.ping(text, from: from) }
        { 'to' => to.name, 'entry' => entry, 'pinged' => targets.map(&:name) }
      end
    end

    def read_messages(args, session)
      profile = registered_profile(session)
      source, room = read_target(args)
      read_stream(profile, source, room, limit(args))
    end

    # The no-idle loop's bottom rung: block until something lands, so an agent
    # that has nothing to say is reachable instead of dark. The wait is a
    # registry entry in this process, not a poll - and since the signal that
    # would clear it cannot cross a process boundary, it also watches the files
    # a line would land in, which costs a couple of stats a second and no reads
    # at all.
    def wait_for_message(args, session)
      profile = registered_profile(session)
      source, room = read_target(args)
      raise ProfileStore::Error, 'Pings interrupt; they cannot be waited on' if source == 'pings'

      if source == 'inbox'
        profile.inbox.wait(timeout: wait_timeout(args))
      else
        room.wait(profile, timeout: wait_timeout(args))
      end
      read_stream(profile, source, room, limit(args))
    end

    def list_rooms(session)
      profile = registered_profile(session)
      @bus.rooms.map do |room|
        entries = room.messages
        {
          'name' => room.name,
          'count' => entries.length,
          'unread' => room.unread(profile).length,
          'lastTs' => entries.last&.fetch('ts', nil)
        }
      end
    end

    def get_heartbeat(args)
      profile = @bus.profile_named(args['name'])
      raise ProfileStore::Error, "Unknown profile: #{args['name']}" unless profile

      heartbeat = profile.heartbeat
      {
        'name' => profile.name,
        'lastHeartbeat' => heartbeat,
        'online' => heartbeat.positive? && (Time.now.to_f * 1000).round - heartbeat < ONLINE_MS
      }
    end

    # Presence rides on ordinary use, so a heartbeat needs no timer: the
    # caller's own profile is stamped by whatever tool it just called. A
    # session that has not registered yet has nobody to stamp.
    def stamp_heartbeat(session)
      profile = @bus.profile(session)
      profile&.touch_heartbeat()
    rescue ProfileStore::Error
      nil
    end

    def profile_entry(profile)
      profile && { 'name' => profile.name, 'directory' => profile.directory }
    end

    def read_target(args)
      source = args['source'].to_s
      source = 'room' if source.empty?
      raise ProfileStore::Error, "Unknown source: #{source}" unless SOURCES.include?(source)

      [source, @bus.room(args['room'])]
    end

    def read_stream(profile, source, room, limit)
      case source
      when 'inbox'
        { 'source' => 'inbox', 'messages' => profile.inbox.read(limit: limit) }
      when 'pings'
        { 'source' => 'pings', 'messages' => profile.inbox.read_pings() }
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
      profile = @bus.profile(session)
      raise ProfileStore::Error, 'No profile is registered for this session; register one first' unless profile

      profile
    end

    def ping_targets(names, from)
      return [] unless names.is_a?(Array)

      targets = names.map do |name|
        target = @bus.profile_named(name)
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

Coord::Server.new(
  Bus.new(config: Config.load(), store: ProfileStore.new())
).run if $PROGRAM_NAME == __FILE__
