require 'yaml'

require_relative 'config'
require_relative 'profile_store'
require_relative 'jev'

# A policy is a list of access guards plus an ordered list of rules that
# screen a tool call. The guards are named deny boundaries - env, profiles,
# rooms, exec, codebase - that the core enforces before any rule runs; the
# file chooses which are on. Each rule matches on the tool name and any of
# the call's input fields, then `deny`, `allow`, or `screen` (ask the backend
# a typed question and deny when the answer is harmful). `except` on a guard
# or a rule exempts those profiles from that one entry.
#
# The workspace's own .devin/autonom-policy.yml is the policy; a workspace
# without one runs on templates/autonom-policy.yml, the default. A room's
# policy.yml adds rules on top and can only restrict: composition never lets
# a later policy's allow outrank an earlier deny or screen, so a room owner
# cannot grant what the workspace forbids.
module Policy
  class Error < StandardError
  end

  TEMPLATE_FILE = 'templates/autonom-policy.yml'
  DEFAULT_THRESHOLD = 0.5
  ACTIONS = %w[deny allow screen].freeze
  GUARDS = %w[env profiles rooms exec codebase].freeze

  extend self

  def template_path
    File.join(ProfileStore.root, TEMPLATE_FILE)
  end

  # The policy a workspace runs on: its own file when it has one, the default
  # template otherwise. Both missing is a broken install, not an open door.
  def workspace
    @workspace ||= begin
      path = File.file?(Config.policy_path) ? Config.policy_path : template_path
      raise Error, "The workspace has no policy and the default template is missing" unless File.file?(path)

      load(path)
    end
  end

  # Tests and long-lived processes reload when the files may have changed.
  def reset!
    @workspace = nil
  end

  # One policy file: the guards it turns on and the rules it screens with. An
  # absent file is an empty document.
  def load(path)
    return Document.new([], []) unless path && File.file?(path)

    parsed = YAML.safe_load(File.read(path))
    parsed = {} unless parsed.is_a?(Hash)
    access = parsed['access']
    rules = parsed['rules']
    raise Error, "Policy access must be a list: #{path}" unless access.nil? || access.is_a?(Array)
    raise Error, "Policy rules must be a list: #{path}" unless rules.nil? || rules.is_a?(Array)

    Document.new(
      Array(access).map { |entry| Guard.new(entry, path) },
      Array(rules).map { |rule| Rule.new(rule, path) }
    )
  rescue Psych::SyntaxError => error
    raise Error, "Policy is not valid YAML: #{error.class}"
  rescue SystemCallError => error
    raise Error, "Could not read policy: #{error.class}"
  end

  # The decision for a request against one or more policies, most restrictive
  # first: any deny denies, then any screen that reads as harmful denies, and
  # only a clean pass from every policy allows. A matching `allow` never grants
  # against a deny or screen in another policy, which is what makes composition
  # a meet rather than a union.
  def decide(policies, request, jev:)
    Array(policies).flatten.compact.flat_map { |policy| policy.rules }.each do |rule|
      next unless rule.match?(request)
      return [true, rule.reason] if rule.deny?
      next unless rule.screen?
      return [true, rule.reason] if rule.harmful?(request, jev: jev)
    end

    [false, nil]
  end

  # `except` names the profiles an entry does not apply to.
  def exempt_list(raw, source)
    return [] if raw.nil?
    raise Error, "Policy except must be a list of profile names: #{source}" unless raw.is_a?(Array)

    raw.map(&:to_s).reject(&:empty?)
  end

  # A loaded policy file: the guards it turns on and the rules it screens
  # with.
  class Document
    def initialize(access, rules)
      @access = access
      @rules = rules
    end

    attr_reader :access, :rules

    # Whether a named guard denies this profile - on unless the entry exempts
    # it.
    def guard?(name, profile_name)
      @access.any? { |guard| guard.name == name && !guard.exempt?(profile_name) }
    end
  end

  # One entry under `access`: a named deny boundary and the profiles exempt
  # from it. A bare string is shorthand for a guard with no exemptions.
  class Guard
    def initialize(raw, source)
      raw = { 'guard' => raw } if raw.is_a?(String)
      raise Error, "A policy access entry must be a map or a guard name: #{source}" unless raw.is_a?(Hash)

      @name = raw['guard'].to_s
      raise Error, "Unknown policy guard: #{@name.inspect}" unless GUARDS.include?(@name)

      @except = Policy.exempt_list(raw['except'], source)
    end

    attr_reader :name

    def exempt?(profile_name)
      name = profile_name.to_s
      !name.empty? && @except.any? { |entry| entry.casecmp?(name) }
    end
  end

  class Rule
    def initialize(raw, source)
      raise Error, "A policy rule must be a map: #{source}" unless raw.is_a?(Hash)

      @action = raw['action'].to_s
      raise Error, "Unknown policy action: #{@action.inspect}" unless ACTIONS.include?(@action)
      raise Error, "A screen rule needs a question: #{source}" if screen? && !raw['question'].is_a?(Hash)

      @match = raw['match'].is_a?(Hash) ? raw['match'] : {}
      @except = Policy.exempt_list(raw['except'], source)
      @reason = raw['reason']
      @context = raw['context']
      @question = raw['question']
      @threshold = (raw['threshold'] || DEFAULT_THRESHOLD).to_f
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

    # Every filter must match and the profile must not be exempted. `tool` is
    # the tool name; any other key is an input field, matched as a regular
    # expression against its string value.
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

    def harmful?(request, jev:)
      state = {
        'tool_name' => request['tool_name'],
        'tool_input' => JEV::Common.scrub(request['tool_input'] || {}),
        'profile_name' => request['profile_name'],
        'policy' => @context || @question['instructions']
      }
      score = jev.decide(state, { 'harmful' => @question }).dig('harmful', 'noul')
      raise JEV::Error, 'The policy check returned no decision' unless score.is_a?(Numeric)

      score >= @threshold
    end
  end
end
