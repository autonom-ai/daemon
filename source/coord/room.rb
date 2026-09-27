require_relative '../config'
require_relative '../profile_store'
require_relative 'bus'

# Rooms are the workspace-scoped side of the bus: they live under the
# project's .devin directory and never follow a person anywhere.
module Room
  extend self

  def messages(name, project: Config.project_dir)
    Bus.read(path(name, project: project))
  end

  def names(project: Config.project_dir)
    dir = Config.rooms_dir(project: project)
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      entry.delete_suffix('.jsonl') if entry.end_with?('.jsonl')
    end.sort
  end

  def read(name, agent:, limit: nil, project: Config.project_dir, root: ProfileStore::ROOT)
    room = Bus.normalize(name, project: project)
    Bus.read_stream(agent, source(room), messages(room, project: project), limit: limit, root: root)
  end

  def unread(name, agent:, project: Config.project_dir, root: ProfileStore::ROOT)
    room = Bus.normalize(name, project: project)
    messages(room, project: project).drop(Bus.cursor(agent, source(room), root: root))
  end

  def post(name, text, from:, project: Config.project_dir)
    room = Bus.normalize(name, project: project)
    entry = Bus.entry(from: from, text: text)
    Bus.append(path(room, project: project), entry)
    ProfileStore.wake_source(source(room))
    entry
  end

  def wait(name, agent, timeout:, project: Config.project_dir)
    room = Bus.normalize(name, project: project)
    ProfileStore.wait(agent, source(room), timeout: timeout, watch: [path(room, project: project)])
  end

  def path(name, project: Config.project_dir)
    room = Bus.normalize(name, project: project)
    Bus.stream_path(Config.rooms_dir(project: project), "#{room}.jsonl")
  end

  private

  # The stream key a room's read cursor lives under.
  def source(room)
    "room:#{room}"
  end
end
