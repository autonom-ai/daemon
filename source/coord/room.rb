require 'fileutils'
require 'json'

require_relative '../policy/format'
require_relative '../profile_store'
require_relative 'inbox'

# A room is a folder on the bus: its message stream and the profiles that may use it.
#
#   rooms/<name>/messages.jsonl   the stream (same shape as any inbox)
#   rooms/<name>/policy.yml       the room's restrict-only secondary policy
#   rooms/<name>/profiles.json    owner, admins, involved - private to the core
#
# Authority is a ladder: the original owner (the creator, and the human profile)
# manages the admins; the original owner and admins administer the room
# (policy, membership, deletion); involved profiles may read and write; nobody
# else knows the room exists.
class Room
  MESSAGES_FILE = 'messages.jsonl'
  POLICY_FILE = 'policy.yml'
  PROFILES_FILE = 'profiles.json'

  def self.create(name, directory, owner:)
    FileUtils.mkdir_p(directory, mode: 0o700)
    raise ProfileStore::Error, 'Room directory must not be a symlink' if File.symlink?(directory)

    write_new(File.join(directory, MESSAGES_FILE), '')
    write_new(File.join(directory, POLICY_FILE), "rules: []\n")
    write_new(File.join(directory, PROFILES_FILE), JSON.generate('owner' => owner, 'admins' => [], 'involved' => nil))
    new(name, directory)
  end

  def self.write_new(path, contents)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
  end

  def initialize(name, directory)
    @name = name
    @directory = directory
  end

  attr_reader :name, :directory

  # The stream name the bus keys waits and cursors by.
  def stream
    "room:#{@name}"
  end

  def inbox
    @inbox ||= Inbox.new(stream, messages_path)
  end

  def messages_path
    File.join(@directory, MESSAGES_FILE)
  end

  def policy_path
    File.join(@directory, POLICY_FILE)
  end

  def profiles_path
    File.join(@directory, PROFILES_FILE)
  end

  def path
    messages_path
  end

  def messages
    inbox.messages
  end

  def unread(profile)
    inbox.unread(profile)
  end

  def read(profile, limit: nil)
    inbox.read(profile, limit: limit)
  end

  def wait(profile, timeout:)
    inbox.wait(profile, timeout: timeout)
  end

  def policy
    Policy.load(policy_path)
  end

  def owner
    profiles && profiles['owner']
  end

  def admins
    (profiles && profiles['admins']) || []
  end

  def involved
    profiles && profiles['involved']
  end

  def original_owners
    [owner, ProfileStore::HUMAN_NAME].compact.map(&:to_s).reject(&:empty?).uniq
  end

  def original_owner?(name)
    named?(original_owners, name)
  end

  def admin?(name)
    named?(admins, name)
  end

  def administrator?(name)
    original_owner?(name) || admin?(name)
  end

  # `involved` nil is everyone in the clone; a list is exactly those profiles.
  # An unreadable membership file fails closed - nobody but the human owner.
  def involved?(name)
    return false unless profiles
    return true if involved.nil?

    named?(involved, name)
  end

  def visible?(name)
    administrator?(name) || involved?(name)
  end

  def add_admin(name)
    name = name.to_s
    update_profiles do |data|
      data['admins'] = (Array(data['admins']) + [name]).uniq { |admin| admin.downcase }
    end
  end

  def remove_admin(name)
    update_profiles do |data|
      data['admins'] = Array(data['admins']).reject { |admin| admin.casecmp?(name.to_s) }
    end
  end

  def set_involved(names)
    update_profiles do |data|
      data['involved'] = names.nil? ? nil : Array(names).map(&:to_s).reject(&:empty?).uniq
    end
  end

  private

  def profiles
    @profiles ||= read_profiles
  end

  def read_profiles
    parsed = JSON.parse(File.read(profiles_path))
    parsed.is_a?(Hash) ? parsed : nil
  rescue SystemCallError, JSON::ParserError
    nil
  end

  def named?(list, name)
    name = name.to_s
    return false if name.empty?

    list.any? { |entry| entry.casecmp?(name) }
  end

  def update_profiles
    path = profiles_path
    raise ProfileStore::Error, 'Room membership must not be a symlink' if File.symlink?(path)

    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      raw = file.read
      data = raw.strip.empty? ? {} : JSON.parse(raw)
      raise ProfileStore::Error, 'Room membership has an invalid format' unless data.is_a?(Hash)

      yield data
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(data))
      file.flush
      @profiles = data
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update room membership: #{error.class}"
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Room membership has an invalid format'
  end
end
