require 'securerandom'
require 'yaml'

require_relative 'decision'
require_relative 'workspace'

module Policy
  class Error < StandardError
  end

  ACTIONS = %w[deny allow screen].freeze
  GUARDS = %w[env profiles rooms policy exec codebase].freeze

  extend self

  def workspace
    path = Workspace.policy_path
    raise Error, 'The workspace requires .devin/policy.yml' unless File.file?(path)
    raise Error, 'Workspace policy must not be a symlink' if File.symlink?(path)

    load(path)
  end

  def secondary(path)
    path = secondary_path(path)
    File.file?(path) ? load(path) : nil
  end

  def secondary_policies(directory)
    raise Error, 'A policy search directory is required' unless directory.is_a?(String) && !directory.empty?

    directory = File.expand_path(directory, Workspace.project_dir)
    raise Error, 'A policy search directory is required' unless File.directory?(directory)
    raise Error, 'Policy directory must not be a symlink' unless File.realpath(directory) == directory

    Dir.glob(File.join(directory, '**', Workspace::POLICY_FILE)).sort.filter_map do |path|
      next if path == Workspace.policy_path || File.symlink?(path)
      next if block_given? && !yield(path)

      { 'path' => secondary_path(path), 'policy' => raw(path) }
    end
  rescue Psych::Exception, SystemCallError => error
    raise Error, "Could not list secondary policies: #{error.class}"
  end

  def set_secondary(path, value)
    path = secondary_path(path)
    parsed = parse_value(value, path)
    document(parsed, path)
    dir = File.dirname(path)
    tmp = File.join(dir, ".policy-#{Process.pid}-#{SecureRandom.hex(8)}.tmp")
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(YAML.dump(parsed))
      file.flush
      file.fsync
    end
    File.rename(tmp, path)
    { 'path' => path, 'policy' => parsed }
  rescue SystemCallError => error
    raise Error, "Could not save secondary policy: #{error.class}"
  ensure
    File.unlink(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
  end

  def remove_secondary(path)
    path = secondary_path(path)
    raise Error, "Unknown secondary policy: #{path}" unless File.file?(path)

    File.unlink(path)
    { 'path' => path, 'removed' => true }
  rescue SystemCallError => error
    raise Error, "Could not remove secondary policy: #{error.class}"
  end

  def load(path)
    return Document.new([], []) unless path && File.file?(path)

    document(raw(path), path)
  rescue Psych::Exception => error
    raise Error, "Policy is not valid YAML: #{error.class}"
  rescue SystemCallError => error
    raise Error, "Could not read policy: #{error.class}"
  end

  def decide(policies, request, decision: Decision)
    Array(policies).flatten.compact.flat_map(&:rules).each do |rule|
      next unless rule.match?(request)
      return [true, rule.reason] if rule.deny?
      next unless rule.screen?
      return [true, rule.reason] if rule.harmful?(request, decision: decision)
    end

    [false, nil]
  end

  def exempt_list(value, source)
    return [] if value.nil?
    raise Error, "Policy except must be a list of profile names: #{source}" unless value.is_a?(Array)

    value.map(&:to_s).reject(&:empty?)
  end

  private

  def raw(path)
    parsed = YAML.safe_load(File.read(path)) || {}
    raise Error, "Policy must be a map: #{path}" unless parsed.is_a?(Hash)

    parsed
  end

  def parse_value(value, source)
    parsed = value.is_a?(String) ? YAML.safe_load(value) : value
    raise Error, "Policy must be a map: #{source}" unless parsed.is_a?(Hash)

    parsed
  rescue Psych::Exception => error
    raise Error, "Policy is not valid YAML: #{error.class}"
  end

  def document(parsed, source)
    access = parsed['access']
    rules = parsed['rules']
    raise Error, "Policy access must be a list: #{source}" unless access.nil? || access.is_a?(Array)
    raise Error, "Policy rules must be a list: #{source}" unless rules.nil? || rules.is_a?(Array)

    Document.new(
      Array(access).map { |entry| Guard.new(entry, source) },
      Array(rules).map { |rule| Rule.new(rule, source) }
    )
  end

  def secondary_path(path)
    raise Error, 'A secondary policy path is required' unless path.is_a?(String) && !path.empty?

    path = File.expand_path(path, Workspace.project_dir)
    raise Error, 'Secondary policies must be named policy.yml' unless File.basename(path) == Workspace::POLICY_FILE
    raise Error, 'The primary policy is not a secondary policy' if path == Workspace.policy_path
    raise Error, 'Policy directory does not exist' unless File.directory?(File.dirname(path))
    unless File.realpath(File.dirname(path)) == File.dirname(path) && !File.symlink?(path)
      raise Error, 'Secondary policy must not use symlinks'
    end

    path
  end

  class Document
    def initialize(access, rules)
      @access = access
      @rules = rules
    end

    attr_reader :access, :rules

    def guard?(name, profile_name)
      @access.any? { |guard| guard.name == name && !guard.exempt?(profile_name) }
    end
  end

  class Guard
    def initialize(value, source)
      value = { 'guard' => value } if value.is_a?(String)
      raise Error, "A policy access entry must be a map or a guard name: #{source}" unless value.is_a?(Hash)

      @name = value['guard'].to_s
      raise Error, "Unknown policy guard: #{@name.inspect}" unless GUARDS.include?(@name)

      @except = Policy.exempt_list(value['except'], source)
    end

    attr_reader :name

    def exempt?(profile_name)
      name = profile_name.to_s
      !name.empty? && @except.any? { |entry| entry.casecmp?(name) }
    end
  end

  class Rule
    def initialize(value, source)
      raise Error, "A policy rule must be a map: #{source}" unless value.is_a?(Hash)

      @action = value['action'].to_s
      raise Error, "Unknown policy action: #{@action.inspect}" unless ACTIONS.include?(@action)

      @question = question(value['question'])
      raise Error, "A screen rule needs a question: #{source}" if screen? && @question.empty?

      @match = value['match'].is_a?(Hash) ? value['match'] : {}
      @except = Policy.exempt_list(value['except'], source)
      @expose = value['expose']
      raise Error, "Policy expose must be a list of input fields: #{source}" unless @expose.nil? || @expose.is_a?(Array)

      @expose = Array(@expose).map(&:to_s)
      @reason = value['reason']
      @context = value['context']
    end

    attr_reader :action, :reason

    def deny?
      @action == 'deny'
    end

    def allow?
      @action == 'allow'
    end

    def screen?
      @action == 'screen'
    end

    def exempt?(profile_name)
      name = profile_name.to_s
      !name.empty? && @except.any? { |entry| entry.casecmp?(name) }
    end

    def match?(request)
      return false if exempt?(request['profile_name'])
      return true if @match.empty?

      @match.all? do |field, pattern|
        value = field.to_s == 'tool' ? request['tool_name'] : request.dig('tool_input', field.to_s)
        value.is_a?(String) && Regexp.new(pattern.to_s).match?(value)
      end
    rescue RegexpError
      false
    end

    def harmful?(request, decision:)
      state = {
        'tool_name' => request['tool_name'],
        'tool_input' => Decision.scrub(request['tool_input'] || {}, @expose),
        'profile_name' => request['profile_name'],
        'policy' => @context || @question
      }
      ret = decision.harmful?(state, @question)
      raise Decision::Error, 'The policy decision returned no answer' unless ret == true || ret == false

      ret
    end

    private

    def question(value)
      return value.strip if value.is_a?(String)
      return value['instructions'].to_s.strip if value.is_a?(Hash)

      ''
    end
  end
end
