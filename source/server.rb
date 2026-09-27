require_relative 'agent/profile'
require_relative 'room'

require 'json'

module Agent
  class Server
    INFO = { 'name' => 'agent-coord', 'version' => '0.1.0' }.freeze
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    SOURCES = %w[room inbox pings].freeze
    WAIT_SOURCES = %w[room inbox].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    DEFAULT_WAIT = 30
    MAX_WAIT = 60
    ONLINE_MS = 30 * 60_000

    def initialize(root: Store::ROOT, project: Room.project_root)
      @root = root
      @project = project
    end

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      write_lock = Mutex.new
      blocking = []
      input.each_line do |line|
        req = parse(line)
        # A blocking wait must not stall the requests behind it, so it runs on
        # its own thread. Everything else is answered in arrival order — a
        # client that sends set_profile then send_message must not see the two
        # race — and no worker outlives the process with its response unwritten.
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
                           'team room). `ping` names profiles to notify — each gets an unread ping, ' \
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
        Profile.get_profiles(root: @root)
      when 'get_profile'
        Profile.get_profile(session, root: @root)
      when 'set_profile'
        Profile.set_profile(args['name'], session: session, root: @root)
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
    rescue Store::Error, Room::Error => error
      tool_error(error.message)
    end

    def send_message(args, session)
      from = registered_name(session)
      text = args['text'].to_s
      raise Store::Error, 'A message needs text' if text.strip.empty?

      targets = ping_targets(args['ping'], from)
      if args['to'].to_s.empty?
        room = Room.normalize(args['room'], root: @project)
        entry = Room.post(room, text, from: from, root: @project)
        targets.each { |target| Profile.ping(target, text, from: from, room: room, root: @root) }
        { 'room' => room, 'entry' => entry, 'pinged' => targets }
      else
        to = Store.normalize_name(args['to'])
        entry = Profile.dm(to, text, from: from, root: @root)
        targets.each { |target| Profile.ping(target, text, from: from, root: @root) }
        { 'to' => to, 'entry' => entry, 'pinged' => targets }
      end
    end

    def read_messages(args, session)
      name = registered_name(session)
      source, room = read_target(args)
      read_stream(name, source, room, limit(args))
    end

    # The no-idle loop's bottom rung: block until something lands, so an agent
    # that has nothing to say is reachable instead of dark. The wait is a
    # registry entry in this process, not a poll — and since the signal that
    # would clear it cannot cross a process boundary, it also watches the files
    # a line would land in, which costs a couple of stats a second and no reads
    # at all.
    def wait_for_message(args, session)
      name = registered_name(session)
      source, room = read_target(args)
      raise Store::Error, 'Pings interrupt; they cannot be waited on' if source == 'pings'

      wait_for(name, source, room, wait_timeout(args))
      read_stream(name, source, room, limit(args))
    end

    def wait_for(name, source, room, timeout)
      if source == 'inbox'
        Profile.wait(name, timeout: timeout, watch: inbox_watch(name))
      else
        Room.wait(room, name, timeout: timeout, watch: room_watch(room, name))
      end
    end

    # A signal only reaches the waiters in the sender's own process and every
    # session runs its own, so a waiter is handed the files its wake would have
    # written: the stream it is parked on, and its own pings — which interrupt
    # any wait, wherever they land.
    def room_watch(room, name)
      [Room.path(room, root: @project), Agent::Store.pings_file(name, root: @root)]
    end

    def inbox_watch(name)
      [Agent::Store.inbox_file(name, root: @root), Agent::Store.pings_file(name, root: @root)]
    end

    def list_rooms(session)
      name = registered_name(session)
      (Room.names(root: @project) | [Room.default_name(root: @project)]).sort.map do |room|
        entries = Room.messages(room, root: @project)
        {
          'name' => room,
          'count' => entries.length,
          'unread' => Profile.unread_room(room, name: name, rooms_root: @project, root: @root).length,
          'lastTs' => entries.last&.fetch('ts', nil)
        }
      end
    end

    def get_heartbeat(args)
      name = Store.normalize_name(args['name'])
      profile = Profile.get_profiles(root: @root).find { |entry| entry['name'].casecmp?(name) }
      raise Store::Error, "Unknown profile: #{name}" unless profile

      heartbeat = Profile.heartbeat(profile['name'], root: @root)
      {
        'name' => profile['name'],
        'lastHeartbeat' => heartbeat,
        'online' => heartbeat.positive? && (Time.now.to_f * 1000).round - heartbeat < ONLINE_MS
      }
    end

    # Presence rides on ordinary use, so a heartbeat needs no timer: the
    # caller's own profile is stamped by whatever tool it just called. A
    # session that has not registered yet has nobody to stamp.
    def stamp_heartbeat(session)
      profile = Profile.get_profile(session, root: @root)
      Profile.touch_heartbeat(profile['name'], root: @root) if profile
    rescue Store::Error
      nil
    end

    def read_target(args)
      source = args['source'].to_s
      source = 'room' if source.empty?
      raise Store::Error, "Unknown source: #{source}" unless SOURCES.include?(source)

      [source, Room.normalize(args['room'], root: @project)]
    end

    def read_stream(name, source, room, limit)
      case source
      when 'inbox'
        { 'source' => 'inbox', 'messages' => Profile.read_inbox(name, limit: limit, root: @root) }
      when 'pings'
        { 'source' => 'pings', 'messages' => Profile.read_pings(name, root: @root) }
      else
        {
          'source' => 'room',
          'room' => room,
          'messages' => Profile.read_room(room, name: name, limit: limit, rooms_root: @project, root: @root)
        }
      end
    end

    def wait_timeout(args)
      value = args['timeout']
      value.is_a?(Integer) ? value.clamp(1, MAX_WAIT) : DEFAULT_WAIT
    end

    def registered_name(session)
      profile = Profile.get_profile(session, root: @root)
      raise Store::Error, 'No profile is registered for this session; register one first' unless profile

      profile['name']
    end

    def ping_targets(names, from)
      return [] unless names.is_a?(Array)

      known = Profile.get_profiles(root: @root).map { |profile| profile['name'] }
      names.filter_map do |name|
        target = known.find { |candidate| candidate.casecmp?(Store.normalize_name(name)) }
        raise Store::Error, "Unknown profile to ping: #{name}" unless target

        target
      end.uniq - [from]
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

Agent::Server.new.run if $PROGRAM_NAME == __FILE__
