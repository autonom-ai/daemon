require 'json'

# The workspace's autonom-config.json: the source of truth for what this
# workspace is and where its coordination files live.
class Config
  FILE = 'autonom-config.json'
  DEVIN_DIR = '.devin'
  ROOMS_DIR = 'autonom-coord/rooms'
  DEFAULT_TEAM_ROOM = 'general'

  # A screening or gating switch: on or off, with an optional backend name.
  Feature = Struct.new(:enabled, :backend) do
    def enabled?
      enabled
    end
  end

  def self.load(project = project_dir())
    new(project)
  end

  def self.project_dir()
    File.expand_path(ENV['DEVIN_PROJECT_DIR'] || Dir.pwd)
  end

  def initialize(project)
    @project_dir = File.expand_path(project)
    @raw = read
  end

  attr_reader :project_dir

  def project
    @raw['project']
  end

  def human
    @raw['human']
  end

  def team_room
    @raw['teamRoom']
  end

  def policy
    feature(@raw.fetch('policy', true))
  end

  def salience
    feature(@raw.fetch('salience', true))
  end

  def memory
    feature(@raw.fetch('memory', false))
  end

  def dir
    File.join(@project_dir, DEVIN_DIR)
  end

  def path
    File.join(dir, FILE)
  end

  def rooms_dir
    File.join(dir, ROOMS_DIR)
  end

  private

  def read()
    raw = JSON.parse(File.read(path))
    raw.is_a?(Hash) ? raw : {}
  rescue SystemCallError, JSON::ParserError
    {}
  end

  def feature(value)
    case value
    when Hash
      Feature.new(value.fetch('enabled', true), value['backend'])
    when String
      Feature.new(true, value)
    when true
      Feature.new(true, nil)
    else
      Feature.new(false, nil)
    end
  end
end
