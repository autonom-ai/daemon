module Workspace
  DEVIN_DIR = '.devin'
  COORD_DIR = 'autonom-coord'
  POLICY_FILE = 'policy.yml'

  extend self

  def project_dir
    File.expand_path(ENV['DEVIN_PROJECT_DIR'] || Dir.pwd)
  end

  def rooms_dir
    File.join(project_dir, DEVIN_DIR, COORD_DIR, 'rooms')
  end

  def policy_path
    File.join(project_dir, DEVIN_DIR, POLICY_FILE)
  end

end
