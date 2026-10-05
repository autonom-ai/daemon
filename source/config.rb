module Config
  DEVIN_DIR = '.devin'
  COORD_DIR = 'autonom-coord'
  POLICY_FILE = 'policy.yml'
  HOOKS_FILE = 'hooks.v1.json'

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

  def hooks_path
    File.join(project_dir, DEVIN_DIR, HOOKS_FILE)
  end

  # Symlinks aren't picked up, so only regular files.
  def has_policy?
    File.file?(policy_path) && !File.symlink?(policy_path)
  end

  def has_hooks?
    File.file?(hooks_path) && !File.symlink?(hooks_path)
  end
end
