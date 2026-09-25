require 'fileutils'
require 'json'
require 'securerandom'

module Agent
  module Store
    ROOT = File.expand_path('../../..', __dir__)
    NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
    INBOX_FILE = 'inbox.jsonl'
    PINGS_FILE = 'pings.jsonl'
    CURSORS_FILE = 'cursors.json'
    HEARTBEAT_FILE = 'heartbeat.json'

    class Error < StandardError
    end

    extend self

    def get_profiles(root: ROOT)
      dir = agents_dir(root)
      return [] unless File.directory?(dir)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

      Dir.children(dir).filter_map do |name|
        next unless valid_name?(name)

        profile = File.join(dir, name)
        next unless File.directory?(profile) && !File.symlink?(profile)

        { 'name' => name, 'directory' => File.realpath(profile) }
      end.sort_by { |profile| profile['name'].downcase }
    end

    def get_profile(session, root: ROOT)
      return nil if session.nil? || session.to_s.empty?

      name = with_lock(root, File::LOCK_SH) do
        read_sessions(root)[validate_session(session)]
      end
      return nil unless name

      profile = find_profile(name, root: root)
      raise Error, 'The registered profile no longer exists' unless profile

      profile
    end

    def set_profile(session, name, root: ROOT)
      session = validate_session(session)
      name = normalize_name(name)

      with_lock(root, File::LOCK_EX) do
        sessions = read_sessions(root)
        current = sessions[session]

        if current
          profile = find_profile(current, root: root)
          raise Error, 'The registered profile no longer exists' unless profile
          raise Error, 'A session profile cannot be changed after registration' unless profile['name'].casecmp?(name)

          next profile
        end

        profile = find_profile(name, root: root) || create_profile(name.downcase, root: root)
        sessions[session] = profile['name']
        write_sessions(sessions, root: root)
        profile
      end
    end

    def valid_name?(name)
      name.is_a?(String) && NAME_PATTERN.match?(name)
    end

    def normalize_name(name)
      name = name.to_s.strip
      raise Error, 'Invalid profile name' unless valid_name?(name)

      name
    end

    def inbox_file(name, root: ROOT)
      chat_file(name, INBOX_FILE, root: root)
    end

    def pings_file(name, root: ROOT)
      chat_file(name, PINGS_FILE, root: root)
    end

    def read_jsonl(path)
      return [] unless File.exist?(path)

      File.read(path).lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError => error
      raise Error, "Could not read chat stream: #{error.class}"
    end

    def append_jsonl(path, entry)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.write("#{JSON.generate(entry)}\n")
      end
    rescue SystemCallError => error
      raise Error, "Could not append to chat stream: #{error.class}"
    end

    # How far this profile has read each stream: "inbox", "pings", and
    # "room:<name>" keys, each holding the entry count already delivered.
    def cursors(name, root: ROOT)
      path = chat_file(name, CURSORS_FILE, root: root)
      File.exist?(path) ? parse_cursors(File.read(path)) : {}
    rescue SystemCallError => error
      raise Error, "Could not read the read cursor: #{error.class}"
    end

    def cursor(name, key, root: ROOT)
      cursors(name, root: root)[key.to_s].to_i
    end

    def advance_cursor(name, key, count, root: ROOT)
      path = chat_file(name, CURSORS_FILE, root: root)
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

    # Presence is explicit, not inferred: a profile is as fresh as the last
    # MCP call it made. Every tool call stamps this, so a heartbeat is a fact
    # about use rather than a liveness probe the caller has to trust.
    def heartbeat(name, root: ROOT)
      path = chat_file(name, HEARTBEAT_FILE, root: root)
      File.exist?(path) ? parse_heartbeat(File.read(path)) : 0
    rescue SystemCallError => error
      raise Error, "Could not read the heartbeat: #{error.class}"
    end

    def touch_heartbeat(name, root: ROOT)
      path = chat_file(name, HEARTBEAT_FILE, root: root)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.truncate(0)
        file.rewind
        file.write(JSON.generate('ts' => (Time.now.to_f * 1000).round))
        file.flush
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue SystemCallError => error
      raise Error, "Could not update the heartbeat: #{error.class}"
    end

    private

    def parse_heartbeat(raw)
      parsed = raw.strip.empty? ? {} : JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed['ts'].to_i : 0
    rescue JSON::ParserError
      0
    end

    def parse_cursors(raw)
      parsed = raw.strip.empty? ? {} : JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def agents_dir(root)
      File.join(File.expand_path(root), 'agents')
    end

    def chat_file(name, file, root:)
      dir = File.join(agents_dir(root), normalize_name(name))
      raise Error, 'Profile directory must not be a symlink' if File.symlink?(dir)

      path = File.join(dir, file)
      raise Error, 'Chat stream must not be a symlink' if File.symlink?(path)

      path
    end

    def find_profile(name, root: ROOT)
      matches = get_profiles(root: root).select { |profile| profile['name'].casecmp?(name.to_s) }
      raise Error, 'Profile names must be unique without regard to case' if matches.length > 1

      matches.first
    end

    def create_profile(name, root: ROOT)
      dir = agents_dir(root)
      FileUtils.mkdir_p(dir)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

      profile = File.join(dir, name)
      FileUtils.mkdir(profile, mode: 0o700)
      FileUtils.mkdir(File.join(profile, 'memories'), mode: 0o700)
      File.open(
        File.join(profile, 'identity.md'),
        File::WRONLY | File::CREAT | File::EXCL,
        0o600
      ) do |file|
        file.write("---\nname: #{name}\ndisplayName: #{name}\n---\n\n# #{name}\n")
      end
      { 'name' => name, 'directory' => File.realpath(profile) }
    rescue SystemCallError => error
      raise Error, "Could not create profile: #{error.class}"
    end

    def validate_session(session)
      session = session.to_s
      raise Error, 'A valid session ID is required' if session.empty? || session.length > 512 || session.include?("\0")

      session
    end

    def with_lock(root, mode)
      dir = agents_dir(root)
      FileUtils.mkdir_p(dir)
      raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

      path = File.join(dir, 'sessions.json.lock')
      raise Error, 'Session lock must not be a symlink' if File.symlink?(path)

      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        File.chmod(0o600, path)
        file.flock(mode)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue SystemCallError => error
      raise Error, "Could not lock session mappings: #{error.class}"
    end

    def read_sessions(root)
      path = File.join(agents_dir(root), 'sessions.json')
      return {} unless File.exist?(path)
      raise Error, 'Session mapping file must not be a symlink' if File.symlink?(path)

      File.chmod(0o600, path)
      sessions = JSON.parse(File.read(path))
      unless sessions.is_a?(Hash) && sessions.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        raise Error, 'Session mapping file has an invalid format'
      end

      sessions
    rescue JSON::ParserError
      raise Error, 'Session mapping file contains invalid JSON'
    rescue SystemCallError => error
      raise Error, "Could not read session mappings: #{error.class}"
    end

    def write_sessions(sessions, root: ROOT)
      dir = agents_dir(root)
      path = File.join(dir, 'sessions.json')
      tmp = File.join(dir, ".sessions-#{Process.pid}-#{SecureRandom.hex(8)}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(sessions))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
    rescue SystemCallError => error
      raise Error, "Could not save session mapping: #{error.class}"
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end
  end
end
