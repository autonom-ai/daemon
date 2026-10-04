require 'fileutils'
require 'json'
require 'securerandom'

require_relative 'profile'

module ProfileStore
  ROOT = File.expand_path('..', __dir__)
  NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  SESSIONS_FILE = 'sessions.json'
  HUMAN_NAME = 'human'

  class Error < StandardError
  end

  extend self

  def root
    @root ||= ROOT
  end

  def root=(path)
    @root = File.expand_path(path)
  end

  def profiles
    ensure_human
    dir = agents_dir
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

    Dir.children(dir).filter_map do |name|
      next unless valid_name?(name)

      directory = File.join(dir, name)
      next unless File.directory?(directory) && !File.symlink?(directory)

      Profile.new(name, File.realpath(directory))
    end.sort_by { |profile| profile.name.downcase }
  end

  def profile_by_session(session)
    key = session.to_s
    return nil if key.empty?

    with_lock(File::LOCK_SH) do
      name = read_sessions[key]
      next nil unless name

      profile = profile_by_name(name) || raise(Error, 'The registered profile no longer exists')
      current = profile.session_id
      current.nil? || current == key ? profile : nil
    end
  end

  def profile_by_name(name)
    matches = profiles.select { |profile| profile.name.casecmp?(name.to_s) }
    raise Error, 'Profile names must be unique without regard to case' if matches.length > 1

    matches.first
  end

  def register_profile(name, session)
    key = session.to_s
    raise Error, 'A valid session ID is required' if key.empty?

    name = name.to_s.strip
    raise Error, 'Invalid profile name' unless valid_name?(name)
    raise Error, 'The human profile cannot be registered to an agent session' if name.casecmp?(HUMAN_NAME)

    with_lock(File::LOCK_EX) do
      sessions = read_sessions
      current_name = sessions[key]
      existing = current_name ? profile_by_name(current_name) : profile_by_name(name)
      raise Error, 'The registered profile no longer exists' if current_name && !existing
      if current_name && !existing.name.casecmp?(name)
        raise Error, 'A session profile cannot be changed after registration'
      end

      existing ||= create(name.downcase)
      current_session = existing.session_id
      if current_session && current_session != key && existing.online?
        raise Error, 'The profile is already mapped to an online session'
      end

      existing.bind_session(key) unless current_session == key
      sessions[key] = existing.name
      write_sessions(sessions) unless current_name && current_session == key
      existing
    end
  end

  def valid_name?(name)
    name.is_a?(String) && NAME_PATTERN.match?(name)
  end

  private

  def agents_dir
    File.join(root, 'agents')
  end

  def ensure_human
    dir = agents_dir
    directory = File.join(dir, HUMAN_NAME)
    return if File.directory?(directory) && !File.symlink?(directory)

    create(HUMAN_NAME)
  end

  def create(name)
    dir = agents_dir
    FileUtils.mkdir_p(dir)
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

    directory = File.join(dir, name)
    FileUtils.mkdir(directory, mode: 0o700)
    File.open(
      File.join(directory, 'identity.md'),
      File::WRONLY | File::CREAT | File::EXCL,
      0o600
    ) do |file|
      file.write("---\nname: #{name}\ndisplayName: #{name}\n---\n\n# #{name}\n")
    end
    Profile.new(name, File.realpath(directory))
  rescue Errno::EEXIST
    raise Error, 'Profile already exists' unless name == HUMAN_NAME && File.directory?(directory)
    raise Error, 'Human profile must not be a symlink' if File.symlink?(directory)

    Profile.new(name, File.realpath(directory))
  rescue SystemCallError => error
    raise Error, "Could not create profile: #{error.class}"
  end

  def with_lock(mode)
    dir = agents_dir
    FileUtils.mkdir_p(dir)
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

    path = File.join(dir, "#{SESSIONS_FILE}.lock")
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

  def read_sessions()
    path = File.join(agents_dir, SESSIONS_FILE)
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

  def write_sessions(sessions)
    dir = agents_dir
    path = File.join(dir, SESSIONS_FILE)
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
