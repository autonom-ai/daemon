require 'fileutils'
require 'json'
require 'securerandom'

require_relative 'profile'

module ProfileStore
  ROOT = File.expand_path('..', __dir__)
  NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  SESSIONS_FILE = 'sessions.json'

  class Error < StandardError
  end

  Record = Struct.new(:name, :directory)

  extend self

  def root
    @root ||= ROOT
  end

  def root=(path)
    @root = File.expand_path(path)
  end

  def records
    dir = agents_dir
    return [] unless File.directory?(dir)
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

    Dir.children(dir).filter_map do |name|
      next unless valid_name?(name)

      profile = File.join(dir, name)
      next unless File.directory?(profile) && !File.symlink?(profile)

      Record.new(name, File.realpath(profile))
    end.sort_by { |record| record.name.downcase }
  end

  def record(name)
    matches = records.select { |record| record.name.casecmp?(name.to_s) }
    raise Error, 'Profile names must be unique without regard to case' if matches.length > 1

    matches.first
  end

  def session(session)
    return nil if session.nil? || session.to_s.empty?

    name = with_lock(File::LOCK_SH) { read_sessions[session] }
    return nil unless name

    stored = record(name)
    raise Error, 'The registered profile no longer exists' unless stored

    stored
  end

  def register(session, name)
    raise Error, 'A valid session ID is required' if session.nil? || session.to_s.empty?
    name = normalize_name(name)

    stored = with_lock(File::LOCK_EX) do
      sessions = read_sessions
      current = sessions[session]

      if current
        existing = record(current)
        raise Error, 'The registered profile no longer exists' unless existing
        raise Error, 'A session profile cannot be changed after registration' unless existing.name.casecmp?(name)

        next existing
      end

      existing = record(name) || create(name.downcase)
      sessions[session] = existing.name
      write_sessions(sessions)
      existing
    end

    profile_from(stored)
  end

  def directory(name)
    dir = agents_dir
    raise Error, 'Agent profile directory must not be a symlink' if File.symlink?(dir)

    profile = File.join(dir, normalize_name(name))
    raise Error, 'Profile directory must not be a symlink' if File.symlink?(profile)

    profile
  end

  def profiles
    records.map { |record| profile_from(record) }
  end

  def profile(session)
    stored = session(session)
    stored && profile_from(stored)
  end

  def profile_named(name)
    stored = record(name)
    stored && profile_from(stored)
  end

  def valid_name?(name)
    name.is_a?(String) && NAME_PATTERN.match?(name)
  end

  def normalize_name(name)
    name = name.to_s.strip
    raise Error, 'Invalid profile name' unless valid_name?(name)

    name
  end

  private

  def agents_dir
    File.join(root, 'agents')
  end

  def profile_from(record)
    Profile.new(record.name, record.directory)
  end

  def create(name)
    dir = agents_dir
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
    Record.new(name, File.realpath(profile))
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
