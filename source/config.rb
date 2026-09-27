require 'json'

# The workspace's autonom-config.json: the single source of truth for what
# this workspace is and where its coordination files live. A pure reader -
# it never normalizes names and never touches the bus.
module Config
  FILE = 'autonom-config.json'
  DEVIN_DIR = '.devin'
  ROOMS_DIR = 'autonom-coord/rooms'

  POLICY_DEFAULTS = { 'enabled' => true, 'backend' => nil }.freeze
  SALIENCE_DEFAULTS = { 'enabled' => true, 'backend' => nil }.freeze
  MEMORY_DEFAULTS = { 'enabled' => true, 'backend' => nil }.freeze

  extend self

  def load(project: project_dir)
    root = File.expand_path(project)
    raw = read(root)
    {
      'project_dir' => root,
      'project' => raw['project'],
      'human' => raw['human'],
      'team_room' => raw['teamRoom'],
      'policy' => feature(raw.fetch('policy', true), POLICY_DEFAULTS),
      'salience' => feature(raw.fetch('salience', true), SALIENCE_DEFAULTS),
      'memory' => feature(raw.fetch('memory', false), MEMORY_DEFAULTS)
    }
  end

  def project_dir
    File.expand_path(ENV['DEVIN_PROJECT_DIR'] || Dir.pwd)
  end

  def dir(project: project_dir)
    File.join(File.expand_path(project), DEVIN_DIR)
  end

  def path(project: project_dir)
    File.join(dir(project: project), FILE)
  end

  def rooms_dir(project: project_dir)
    File.join(dir(project: project), ROOMS_DIR)
  end

  def team_room(project: project_dir)
    read(File.expand_path(project))['teamRoom']
  end

  private

  def read(project)
    raw = JSON.parse(File.read(path(project: project)))
    raw.is_a?(Hash) ? raw : {}
  rescue SystemCallError, JSON::ParserError
    {}
  end

  def feature(value, defaults)
    case value
    when Hash
      defaults.merge(value).merge('enabled' => value.fetch('enabled', true))
    when String
      defaults.merge('enabled' => true, 'backend' => value)
    when true
      defaults.merge('enabled' => true)
    else
      defaults.merge('enabled' => false)
    end
  end
end
