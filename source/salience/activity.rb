require 'fileutils'
require 'json'

# What a profile has been doing, as drives. Every tool call lands in a
# category - social (the coord tools), work (producing), explore (looking
# around) - refilling its own drive and draining the others, and every drive
# decays with time. A starved drive is what the impulse layer nudges: the
# quiet room, the unfinished thread, the lead worth chasing.
module Salience
  module Activity
    class Error < StandardError
    end

    FILE = 'activity.json'
    DRIVES = %w[social work explore].freeze
    HALF_LIFE = { 'social' => 900, 'work' => 2700, 'explore' => 1800 }.freeze
    START = 0.75
    STARVED = 0.45
    BOOST = 0.25
    DRAIN = 0.08
    MAX_DETAIL = 120
    COORD_PREFIX = 'mcp__autonom-coord-mcp__'
    CATEGORIES = {
      'social' => %w[
        send_message read_messages wait_for_message list_rooms get_heartbeat
        get_profiles get_profile set_profile create_room delete_room
        set_room_involved add_room_admin remove_room_admin
      ],
      'work' => %w[write edit notebook_edit apply_patch exec get_output write_to_process kill_shell todo_write],
      'explore' => %w[read notebook_read grep glob webfetch run_subagent read_subagent skill]
    }.freeze

    extend self

    # Advisory telemetry: a failed write must never break the tool call it
    # rides on, so this stays quiet.
    def record(profile, tool, input = nil, now: nil)
      now ||= Time.now
      state = read(profile)
      drives = decayed(state['drives'], state['ts'], now)
      drive = category(tool)
      if drive
        DRIVES.each { |name| drives[name] = shift(drives[name], name == drive ? BOOST : -DRAIN) }
      end
      write(
        profile,
        'ts' => (now.to_f * 1000).round,
        'calls' => state['calls'].to_i + 1,
        'drives' => drives,
        'last' => last_entry(tool, input, now)
      )
    rescue Error, SystemCallError
      nil
    end

    # The drives as of now, plus what the profile last touched.
    def state(profile, now: nil)
      now ||= Time.now
      raw = read(profile)
      {
        'drives' => decayed(raw['drives'], raw['ts'], now),
        'calls' => raw['calls'].to_i,
        'last' => raw['last']
      }
    rescue Error, SystemCallError
      { 'drives' => decayed(nil, nil, now), 'calls' => 0, 'last' => nil }
    end

    # The weakest drive below the starvation line, or nil when all are fed.
    # Ties break in DRIVES order, so the room comes first.
    def starved(state)
      name, level = state['drives'].min_by { |drive, value| value }
      level && level < STARVED ? name : nil
    end

    def category(tool)
      name = tool.to_s
      return 'social' if name.start_with?(COORD_PREFIX)
      return 'explore' if name.start_with?('mcp__')

      CATEGORIES.find { |_drive, tools| tools.include?(name) }&.first
    end

    private

    def read(profile)
      path = path(profile)
      return {} unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def write(profile, state)
      path = path(profile)
      raise Error, 'Activity file must not be a symlink' if File.symlink?(path)

      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.truncate(0)
        file.rewind
        file.write(JSON.generate(state))
        file.flush
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def path(profile)
      File.join(profile.directory, FILE)
    end

    def decayed(drives, ts, now)
      elapsed = ts.to_i.positive? ? [now.to_f - ts.to_i / 1000.0, 0].max : 0.0
      DRIVES.to_h do |drive|
        level = drives.is_a?(Hash) ? drives[drive] : nil
        level = START unless level.is_a?(Numeric)
        [drive, decay(level, elapsed, HALF_LIFE.fetch(drive))]
      end
    end

    def decay(level, elapsed, half_life)
      (level * (0.5**(elapsed / half_life))).clamp(0.0, 1.0)
    end

    def shift(level, amount)
      (level + amount).clamp(0.0, 1.0)
    end

    def last_entry(tool, input, now)
      input = input.is_a?(Hash) ? input : {}
      detail = input['file_path'] || input['notebook_path'] || input['path'] ||
               input['pattern'] || input['command'] || input['room'] || input['text'] || input['to']
      {
        'tool' => tool.to_s,
        'detail' => detail.to_s[0, MAX_DETAIL],
        'ts' => (now.to_f * 1000).round
      }
    end
  end
end
