require 'fileutils'
require 'securerandom'

require_relative '../profile_store'
require_relative '../workspace'
require_relative 'inbox'
require_relative 'stream_store'
require_relative 'room'

module Bus
  DMS_PREFIX = 'dms'
  PINGS_PREFIX = 'pings'
  DMS_FILE = 'dms.jsonl'
  PINGS_FILE = 'pings.jsonl'
  MAX_ENTRY = 400

  class WaitRegistry
    FIRST_SLICE = 0.05
    MAX_SLICE = 0.5

    Ticket = Struct.new(:woken)

    def initialize()
      @lock = Mutex.new
      @condition = ConditionVariable.new
      @entries = {}
    end

    def wait(profile_name, stream_name, timeout:, watch_paths: [])
      # The files are read before the waiter is registered: a line that lands
      # in the gap is a change the waiter can still see on its next slice, and
      # one that lands after registration is a change too.
      baseline = fingerprint(watch_paths)
      ticket = Ticket.new(false)
      @lock.synchronize { ((@entries[stream_name] ||= {})[profile_name] ||= []) << ticket }
      park(ticket, timeout, watch_paths, baseline)
    ensure
      @lock.synchronize do
        parked = @entries.dig(stream_name, profile_name)
        parked&.delete(ticket)
        @entries[stream_name]&.delete(profile_name) if parked&.empty?
        @entries.delete(stream_name) if @entries[stream_name]&.empty?
      end
    end

    def wake(profile_name, stream_name)
      signal() { Array(@entries.dig(stream_name, profile_name)) }
    end

    def wake_agent(profile_name)
      signal() { @entries.values.flat_map { |streams| Array(streams[profile_name]) } }
    end

    def wake_source(stream_name)
      signal() { Array(@entries[stream_name]&.values&.flatten) }
    end

    private

    def signal()
      @lock.synchronize do
        yield.each { |ticket| ticket.woken = true }
        @condition.broadcast
      end
    end

    # Sleeps until slice change.
    def park(ticket, timeout, watch_paths, baseline)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      slice = FIRST_SLICE
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if remaining <= 0

        @lock.synchronize do
          @condition.wait(@lock, watch_paths.empty? ? remaining : [slice, remaining].min) unless ticket.woken
          return if ticket.woken
        end
        return if fingerprint(watch_paths) != baseline

        slice = [slice * 2, MAX_SLICE].min
      end
    end

    # Detects when a file has been replaced, added, or modified.
    def fingerprint(watch_paths)
      watch_paths.map do |file_path|
        stat = File.stat(file_path)
        [stat.size, stat.mtime.to_f, stat.ino]
      rescue SystemCallError
        nil
      end
    end
  end

  WAITERS = WaitRegistry.new

  extend self

  def rooms
    rooms_dir = Workspace.rooms_dir
    return [] unless File.directory?(rooms_dir)

    Dir.children(rooms_dir).filter_map do |room_name|
      next unless ProfileStore.valid_name?(room_name)

      room_dir = File.join(rooms_dir, room_name)
      next unless File.directory?(room_dir) && !File.symlink?(room_dir)

      Room.new(room_name, room_dir)
    end.sort_by(&:name)
  end

  def room_by_name(room_name)
    room_name = normalize_room_name(room_name)
    return nil unless room_name

    rooms.find { |room| room.name == room_name }
  end

  def visible_rooms(profile)
    rooms.select { |room| room.visible?(profile && profile.name) }
  end

  def create_room(room_name, owner_profile_name:)
    room_name = normalize_room_name(room_name)
    raise Error, 'Invalid room name' unless room_name
    raise Error, "Room already exists: #{room_name}" if room_by_name(room_name)

    Room.create(room_name, room_directory(room_name), owner_profile_name: owner_profile_name)
  rescue SystemCallError => error
    raise Error, "Could not create room: #{error.class}"
  end

  def delete_room(room_name)
    room = room_by_name(room_name)
    raise Error, "Unknown room: #{room_name}" unless room

    FileUtils.remove_entry(room.directory)
    wake_source(room.stream)
    room
  rescue SystemCallError => error
    raise Error, "Could not delete room: #{error.class}"
  end

  def dms_by_profile(profile)
    Inbox.new(
      "#{DMS_PREFIX}:#{profile.name}",
      StreamStore.path(profile.directory, DMS_FILE),
      watch_paths: [pings_path(profile)]
    )
  end

  def pings_by_profile(profile)
    Inbox.new("#{PINGS_PREFIX}:#{profile.name}", pings_path(profile))
  end

  def unread(profile)
    {
      'pings' => pings_by_profile(profile).unread(profile),
      'dms' => dms_by_profile(profile).unread(profile),
      'rooms' => visible_rooms(profile).to_h { |room| [room.stream, room.inbox.unread(profile)] }
    }
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
      room_suffix = entry['room'] ? " in ##{entry['room']}" : ''
      "[#{clock(entry['ts'])}] #{entry['from']}#{room_suffix}: #{clip(entry['text'], MAX_ENTRY)}"
    end
  end

  def post(room, text, from:)
    entry = entry(from: from, text: text)
    StreamStore.append(room.messages_path, entry)
    from.policy = room.policy_path
    wake_source(room.stream)
    entry
  end

  def dm(to, text, from:)
    inbox = dms_by_profile(to)
    entry = entry(from: from, text: text, to: to)
    StreamStore.append(inbox.file_path, entry)
    wake(to, inbox.stream_name)
    entry
  end

  def ping(profile, text, from:, room: nil)
    inbox = pings_by_profile(profile)
    entry = entry(from: from, text: text, room: room)
    StreamStore.append(inbox.file_path, entry)
    # A ping interrupts anything: it ends an inbox wait and any room wait
    # this person is parked in.
    wake_agent(profile)
    entry
  end

  def wait(profile, stream_name, timeout:, watch_paths: [])
    WAITERS.wait(profile.name, stream_name, timeout: timeout, watch_paths: watch_paths)
  end

  def wake(profile, stream_name)
    WAITERS.wake(profile.name, stream_name)
  end

  def wake_agent(profile)
    WAITERS.wake_agent(profile.name)
  end

  def wake_source(stream_name)
    WAITERS.wake_source(stream_name)
  end

  private

  def normalize_room_name(room_name)
    room_name = room_name.to_s.strip.sub(/\A#/, '').downcase
    ProfileStore.valid_name?(room_name) ? room_name : nil
  end

  def room_directory(room_name)
    rooms_dir = Workspace.rooms_dir
    raise Error, 'Room directory must not be a symlink' if File.symlink?(rooms_dir)

    FileUtils.mkdir_p(rooms_dir, mode: 0o700)
    room_dir = File.join(rooms_dir, room_name)
    raise Error, 'Room directory must not be a symlink' if File.symlink?(room_dir)

    room_dir
  end

  def pings_path(profile)
    StreamStore.path(profile.directory, PINGS_FILE)
  end

  def clock(ts)
    Time.at(ts.to_i / 1000.0).strftime('%H:%M:%S')
  end

  def clip(value, max)
    text = value.to_s
    text.length <= max ? text : "#{text[0, max - 1]}…"
  end
end
