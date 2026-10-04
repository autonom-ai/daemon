require 'fileutils'
require 'json'
require 'securerandom'

require_relative '../profile_store'
require_relative '../workspace'
require_relative 'inbox'
require_relative 'room'

module Bus
  DMS_PREFIX = 'dms'
  PINGS_PREFIX = 'pings'
  DMS_FILE = 'dms.jsonl'
  PINGS_FILE = 'pings.jsonl'
  CURSORS_FILE = 'cursors.json'
  MAX_ENTRY = 400

  class Error < StandardError
  end

  class WaitRegistry
    FIRST_SLICE = 0.05
    MAX_SLICE = 0.5

    Ticket = Struct.new(:woken)

    def initialize()
      @lock = Mutex.new
      @condition = ConditionVariable.new
      @entries = {}
    end

    def wait(agent, source, timeout:, watch: [])
      # The files are read before the waiter is registered: a line that lands
      # in the gap is a change the waiter can still see on its next slice, and
      # one that lands after registration is a change too.
      baseline = fingerprint(watch)
      ticket = Ticket.new(false)
      @lock.synchronize { ((@entries[source] ||= {})[agent] ||= []) << ticket }
      park(ticket, timeout, watch, baseline)
    ensure
      @lock.synchronize do
        parked = @entries.dig(source, agent)
        parked&.delete(ticket)
        @entries[source]&.delete(agent) if parked&.empty?
        @entries.delete(source) if @entries[source]&.empty?
      end
    end

    def wake(agent, source)
      signal() { Array(@entries.dig(source, agent)) }
    end

    def wake_agent(agent)
      signal() { @entries.values.flat_map { |agents| Array(agents[agent]) } }
    end

    def wake_source(source)
      signal() { Array(@entries[source]&.values&.flatten) }
    end

    private

    def signal()
      @lock.synchronize do
        yield.each { |ticket| ticket.woken = true }
        @condition.broadcast
      end
    end

    # Sleeps until slice change.
    def park(ticket, timeout, watch, baseline)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      slice = FIRST_SLICE
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if remaining <= 0

        @lock.synchronize do
          @condition.wait(@lock, watch.empty? ? remaining : [slice, remaining].min) unless ticket.woken
          return if ticket.woken
        end
        return if fingerprint(watch) != baseline

        slice = [slice * 2, MAX_SLICE].min
      end
    end

    # Detects when a file has been replaced, added, or modified.
    def fingerprint(paths)
      paths.map do |path|
        stat = File.stat(path)
        [stat.size, stat.mtime.to_f, stat.ino]
      rescue SystemCallError
        nil
      end
    end
  end

  WAITERS = WaitRegistry.new

  extend self

  def rooms
    dir = Workspace.rooms_dir
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      next unless ProfileStore.valid_name?(entry)

      path = File.join(dir, entry)
      next unless File.directory?(path) && !File.symlink?(path)

      Room.new(entry, path)
    end.sort_by(&:name)
  end

  def room_by_name(name)
    name = room_name(name)
    return nil unless name

    rooms.find { |room| room.name == name }
  end

  def visible_rooms(profile)
    rooms.select { |room| room.visible?(profile && profile.name) }
  end

  def create_room(name, owner:)
    name = room_name(name)
    raise Error, 'Invalid room name' unless name
    raise Error, "Room already exists: #{name}" if room_by_name(name)

    Room.create(name, room_directory(name), owner: owner)
  rescue SystemCallError => error
    raise Error, "Could not create room: #{error.class}"
  end

  def delete_room(name)
    room = room_by_name(name)
    raise Error, "Unknown room: #{name}" unless room

    FileUtils.remove_entry(room.directory)
    wake_source(room.stream)
    room
  rescue SystemCallError => error
    raise Error, "Could not delete room: #{error.class}"
  end

  def dms_by_profile(profile)
    Inbox.new(
      "#{DMS_PREFIX}:#{profile.name}",
      stream_path(profile.directory, DMS_FILE),
      watch: [pings_path(profile)]
    )
  end

  def dms_by_name(name)
    profile = ProfileStore.profile_by_name(name)
    raise Error, "Unknown profile: #{name}" unless profile

    dms_by_profile(profile)
  end

  def pings_by_profile(profile)
    Inbox.new("#{PINGS_PREFIX}:#{profile.name}", pings_path(profile))
  end

  def pings_by_name(name)
    profile = ProfileStore.profile_by_name(name)
    raise Error, "Unknown profile: #{name}" unless profile

    pings_by_profile(profile)
  end

  def unread(profile)
    {
      'pings' => pings_by_profile(profile).unread(profile),
      'dms' => dms_by_profile(profile).unread(profile),
      'rooms' => visible_rooms(profile).to_h { |room| [room.stream, room.unread(profile)] }
    }
  end

  def read(path)
    return [] unless File.exist?(path)

    File.read(path).lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  rescue SystemCallError => error
    raise Error, "Could not read chat stream: #{error.class}"
  end

  def append(path, entry)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
      file.write("#{JSON.generate(entry)}\n")
    end
  rescue SystemCallError => error
    raise Error, "Could not append to chat stream: #{error.class}"
  end

  def entry(from:, text:, to: nil, room: nil)
    entry = {
      'id' => SecureRandom.uuid,
      'ts' => (Time.now.to_f * 1000).round,
      'from' => from.name,
      'text' => text.to_s
    }
    entry['to'] = to.name if to
    entry['room'] = room.stream if room
    entry
  end

  def format_entries(entries)
    entries.map do |entry|
      room = entry['room'] ? " in ##{entry['room']}" : ''
      "[#{clock(entry['ts'])}] #{entry['from']}#{room}: #{clip(entry['text'], MAX_ENTRY)}"
    end
  end

  def post(room, text, from:)
    entry = entry(from: from, text: text)
    append(room.path, entry)
    from.policy = room.policy_path
    wake_source(room.stream)
    entry
  end

  def dm(to, text, from:)
    inbox = dms_by_profile(to)
    entry = entry(from: from, text: text, to: to)
    append(inbox.path, entry)
    wake(to, inbox.name)
    entry
  end

  def ping(profile, text, from:, room: nil)
    inbox = pings_by_profile(profile)
    entry = entry(from: from, text: text, room: room)
    append(inbox.path, entry)
    # A ping interrupts anything: it ends an inbox wait and any room wait
    # this person is parked in.
    wake_agent(profile)
    entry
  end

  # A stream file must not be a symlink, or an append would land wherever the
  # link points.
  def stream_path(dir, file)
    raise Error, 'Stream directory must not be a symlink' if File.symlink?(dir)

    path = File.join(dir, file)
    raise Error, 'Stream file must not be a symlink' if File.symlink?(path)

    path
  end

  def cursor(profile, key)
    cursors(profile)[key.to_s].to_i
  end

  def advance_cursor(profile, key, count)
    path = cursors_path(profile)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      current = parse_cursors(file.read)
      next if current[key.to_s].to_i >= count

      current[key.to_s] = count
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(current))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise Error, "Could not update the read cursor: #{error.class}"
  end

  # Unread entries, and reading advances the cursor: a stream is delivered
  # once. A first read starts with the newest `limit` entries instead of the
  # whole backlog.
  def read_stream(profile, key, entries, limit: nil)
    seen = cursor(profile, key)
    unread = seen.zero? && limit ? entries.last(limit) : entries.drop(seen)
    advance_cursor(profile, key, entries.length)
    unread
  end

  def wait(profile, source, timeout:, watch: [])
    WAITERS.wait(profile.name, source, timeout: timeout, watch: watch)
  end

  def wake(profile, source)
    WAITERS.wake(profile.name, source)
  end

  def wake_agent(profile)
    WAITERS.wake_agent(profile.name)
  end

  def wake_source(source)
    WAITERS.wake_source(source)
  end

  private

  def room_name(name)
    name = name.to_s.strip.sub(/\A#/, '').downcase
    ProfileStore.valid_name?(name) ? name : nil
  end

  def room_directory(name)
    dir = Workspace.rooms_dir
    raise Error, 'Room directory must not be a symlink' if File.symlink?(dir)

    FileUtils.mkdir_p(dir, mode: 0o700)
    path = File.join(dir, name)
    raise Error, 'Room directory must not be a symlink' if File.symlink?(path)

    path
  end

  def pings_path(profile)
    stream_path(profile.directory, PINGS_FILE)
  end

  def cursors(profile)
    path = cursors_path(profile)
    File.exist?(path) ? parse_cursors(File.read(path)) : {}
  rescue SystemCallError => error
    raise Error, "Could not read the read cursor: #{error.class}"
  end

  def cursors_path(profile)
    stream_path(profile.directory, CURSORS_FILE)
  end

  def parse_cursors(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def clock(ts)
    Time.at(ts.to_i / 1000.0).strftime('%H:%M:%S')
  end

  def clip(text, max)
    text = text.to_s
    text.length <= max ? text : "#{text[0, max - 1]}…"
  end
end
