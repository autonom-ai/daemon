require 'fileutils'
require 'json'

require_relative 'identity'
require_relative 'profile_store'
require_relative 'workspace'

class Profile
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

  def self.session_lock_dir=(lock_dir)
    @session_lock_dir = File.expand_path(lock_dir)
  end

  def initialize(profile_name, directory)
    @name = profile_name
    @directory = directory
  end

  attr_reader :name, :directory

  def identity
    @identity ||= Identity.new(self)
  end

  def session_id
    return nil unless File.file?(session_path)

    File.open(session_path, 'r') do |file|
      file.flock(File::LOCK_SH)
      parse_session(file.read)
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the profile session: #{error.class}"
  end

  def bind_session(session_id)
    raise ProfileStore::Error, 'A valid session ID is required' if session_id.to_s.empty?

    File.open(session_path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      File.chmod(0o600, session_path)
      file.truncate(0)
      file.rewind
      file.write(JSON.generate('session_id' => session_id))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
    session_id
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the profile session: #{error.class}"
  end

  def online?
    mapped_session_id = session_id
    return false unless mapped_session_id && SESSION_ID_PATTERN.match?(mapped_session_id)

    lock_dir = self.class.session_lock_dir
    raise ProfileStore::Error, 'Devin session lock directory must not be a symlink' if File.symlink?(lock_dir)
    return false unless File.directory?(lock_dir)

    session_lock_path = File.join(lock_dir, "#{mapped_session_id}.lock")
    raise ProfileStore::Error, 'Devin session lock must not be a symlink' if File.symlink?(session_lock_path)
    return false unless File.file?(session_lock_path)

    File.open(session_lock_path, 'r') do |file|
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
    return nil unless File.file?(policies_path)

    File.open(policies_path, 'r') do |file|
      file.flock(File::LOCK_SH)
      parse_policies(file.read)[Workspace.project_dir]
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the profile policy: #{error.class}"
  end

  def policy=(policy_path)
    unless policy_path.is_a?(String) && File.basename(policy_path) == Workspace::POLICY_FILE
      raise ProfileStore::Error, 'Invalid policy path'
    end

    FileUtils.mkdir_p(File.dirname(policies_path), mode: 0o700)
    File.open(policies_path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      policies = parse_policies(file.read)
      policies[Workspace.project_dir] = policy_path
      file.truncate(0)
      file.rewind
      file.write(JSON.generate(policies))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
    policy_path
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the profile policy: #{error.class}"
  end

  private

  def session_path
    session_state_path = File.join(@directory, SESSION_FILE)
    if File.symlink?(session_state_path)
      raise ProfileStore::Error, 'Profile session state must not be a symlink'
    end

    session_state_path
  end

  def policies_path
    policy_state_path = File.join(@directory, POLICIES_FILE)
    if File.symlink?(policy_state_path)
      raise ProfileStore::Error, 'Profile policy state must not be a symlink'
    end

    policy_state_path
  end

  def parse_session(session_json)
    parsed = session_json.strip.empty? ? {} : JSON.parse(session_json)
    session_id = parsed['session_id'] if parsed.is_a?(Hash)
    unless session_id.is_a?(String) && !session_id.empty?
      raise ProfileStore::Error, 'Profile session state has an invalid format'
    end

    session_id
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Profile session state contains invalid JSON'
  end

  def parse_policies(policies_json)
    ret = policies_json.strip.empty? ? {} : JSON.parse(policies_json)
    unless ret.is_a?(Hash) &&
        ret.all? { |workspace_dir, policy_path| workspace_dir.is_a?(String) && policy_path.is_a?(String) }
      raise ProfileStore::Error, 'Profile policy state has an invalid format'
    end

    ret
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Profile policy state contains invalid JSON'
  end
end
