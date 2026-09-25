require 'json'
require 'securerandom'

require_relative 'agent/store'

module Room
  DEFAULT_ROOM = 'general'

  class Error < StandardError
  end

  extend self

  # Rooms are workspace-scoped: they live under the project's .devin directory
  # and never follow a person anywhere.
  def messages(name, root: project_root)
    Agent::Store.read_jsonl(file(name, root: root))
  end

  def names(root: project_root)
    dir = rooms_dir(root)
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      entry.delete_suffix('.jsonl') if entry.end_with?('.jsonl')
    end.sort
  end

  def post(name, text, from:, root: project_root)
    entry = {
      'id' => SecureRandom.uuid,
      'ts' => (Time.now.to_f * 1000).round,
      'from' => from.to_s,
      'text' => text.to_s
    }
    Agent::Store.append_jsonl(file(name, root: root), entry)
    entry
  end

  def normalize(name, root: project_root)
    name = name.to_s.strip.sub(/\A#/, '').downcase
    name = default_name(root: root) if name.empty?
    raise Error, 'Invalid room name' unless Agent::Store.valid_name?(name)

    name
  end

  # The team room named by the workspace's coord.json, so a bare room name
  # means the room this workspace actually talks in.
  def default_name(root: project_root)
    config = JSON.parse(File.read(File.join(root, '.devin', 'coord.json')))
    name = config['teamRoom'].to_s.strip.sub(/\A#/, '').downcase
    Agent::Store.valid_name?(name) ? name : DEFAULT_ROOM
  rescue SystemCallError, JSON::ParserError
    DEFAULT_ROOM
  end

  def project_root
    File.expand_path(ENV['DEVIN_PROJECT_DIR'] || Dir.pwd)
  end

  private

  def rooms_dir(root)
    File.join(root, '.devin', 'agent-coord', 'rooms')
  end

  def file(name, root:)
    dir = rooms_dir(root)
    raise Error, 'Room directory must not be a symlink' if File.symlink?(dir)

    path = File.join(dir, "#{normalize(name, root: root)}.jsonl")
    raise Error, 'Room file must not be a symlink' if File.symlink?(path)

    path
  end
end
