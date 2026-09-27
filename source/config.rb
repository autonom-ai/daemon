require 'json'

module Config
  FILE = 'autonom-config.json'
  DEVIN_DIR = '.devin'
  ROOMS_DIR = 'autonom-coord/rooms'

  Feature = Struct.new(:enabled, :backend) do
    def enabled?
      enabled
    end
  end

  extend self

  def project_dir
    File.expand_path(ENV['DEVIN_PROJECT_DIR'] || Dir.pwd)
  end

  def dir
    File.join(project_dir, DEVIN_DIR)
  end

  def path
    File.join(dir, FILE)
  end

  def rooms_dir
    File.join(dir, ROOMS_DIR)
  end

  def project
    raw['project']
  end

  def human
    raw['human']
  end

  def default_room
    raw['defaultRoom']
  end

  def policy
    feature(raw.fetch('policy', true))
  end

  def salience
    feature(raw.fetch('salience', true))
  end

  def memory
    feature(raw.fetch('memory', false))
  end

  private

  def raw
    parsed = JSON.parse(File.read(path))
    parsed.is_a?(Hash) ? parsed : {}
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
