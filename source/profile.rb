require 'fileutils'
require 'json'

require_relative 'identity'
require_relative 'profile_store'
require_relative 'workspace'

# TODO: Profile activity log
class Profile
  HEARTBEAT_FILE = 'heartbeat.json'
  POLICIES_FILE = 'policies.json'
  SESSION_FILE = 'session.json'
  SESSION_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/

  def self.session_lock_dir
    @session_lock_dir ||= File.join(
      ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME'],
      'devin',
      'cli',
      'session_locks'
    )
  end

  def self.session_lock_dir=(path)
    @session_lock_dir = File.expand_path(path)
  end

  def initialize(name, directory)
    @name = name
    @directory = directory
  end

  attr_reader :name, :directory

  def identity
    @identity ||= Identity.new(self)
  end

  def session_id
    path = session_path
    return nil unless File.file?(path)

    File.open(path, 'r') do |file|
      file.flock(File::LOCK_SH)
      parse_session(file.read)
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the profile session: #{error.class}"
  end

  def bind_session(session)
    key = session.to_s
    raise ProfileStore::Error, 'A valid session ID is required' if key.empty?

    path = session_path
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      File.chmod(0o600, path)
      file.truncate(0)
      file.rewind
      file.write(JSON.generate('session_id' => key))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
    key
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the profile session: #{error.class}"
  end

  def online?
    session = session_id
    return false unless session && SESSION_ID_PATTERN.match?(session)

    directory = self.class.session_lock_dir
    raise ProfileStore::Error, 'Devin session lock directory must not be a symlink' if File.symlink?(directory)
    return false unless File.directory?(directory)

    path = File.join(directory, "#{session}.lock")
    raise ProfileStore::Error, 'Devin session lock must not be a symlink' if File.symlink?(path)
    return false unless File.file?(path)

    File.open(path, 'r') do |file|
      if file.flock(File::LOCK_EX | File::LOCK_NB)
        file.flock(File::LOCK_UN)
        false
      else
        true
      end
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not inspect the Devin session lock: #{error.class}"
  end

  # Secondary policy is dictated by the room the profile last posted in.
  def policy
    path = policies_path
    return nil unless File.file?(path)

    File.open(path, 'r') do |file|
      file.flock(File::LOCK_SH)
      parse_policies(file.read)[Workspace.project_dir]
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the profile policy: #{error.class}"
  end

  def policy=(path)
    unless path.is_a?(String) && File.basename(path) == Workspace::POLICY_FILE
      raise ProfileStore::Error, 'Invalid policy path'
    end

    state = policies_path
    FileUtils.mkdir_p(File.dirname(state), mode: 0o700)
    File.open(state, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      policies = parse_policies(file.read)
      policies[Workspace.project_dir] = path
      file.truncate(0)
      file.rewind
      file.write(JSON.generate(policies))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
    path
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the profile policy: #{error.class}"
  end

  # Profile heartbeat is determined by last MCP call.
  def heartbeat
    path = heartbeat_path
    File.exist?(path) ? parse_heartbeat(File.read(path)) : 0
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the heartbeat: #{error.class}"
  end

  def touch_heartbeat()
    path = heartbeat_path
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
    raise ProfileStore::Error, "Could not update the heartbeat: #{error.class}"
  end

  private

  def session_path
    path = File.join(@directory, SESSION_FILE)
    raise ProfileStore::Error, 'Profile session state must not be a symlink' if File.symlink?(path)

    path
  end

  def heartbeat_path
    path = File.join(@directory, HEARTBEAT_FILE)
    raise ProfileStore::Error, 'Heartbeat must not be a symlink' if File.symlink?(path)

    path
  end

  def policies_path
    path = File.join(@directory, POLICIES_FILE)
    raise ProfileStore::Error, 'Profile policy state must not be a symlink' if File.symlink?(path)

    path
  end

  def parse_session(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    session = parsed['session_id'] if parsed.is_a?(Hash)
    unless session.is_a?(String) && !session.empty?
      raise ProfileStore::Error, 'Profile session state has an invalid format'
    end

    session
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Profile session state contains invalid JSON'
  end

  def parse_policies(raw)
    ret = raw.strip.empty? ? {} : JSON.parse(raw)
    unless ret.is_a?(Hash) && ret.all? { |dir, path| dir.is_a?(String) && path.is_a?(String) }
      raise ProfileStore::Error, 'Profile policy state has an invalid format'
    end

    ret
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Profile policy state contains invalid JSON'
  end

  def parse_heartbeat(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed['ts'].to_i : 0
  rescue JSON::ParserError
    0
  end
end
