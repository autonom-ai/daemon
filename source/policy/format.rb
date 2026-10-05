require 'yaml'

require_relative '../decision'
require_relative '../workspace'

module Policy
  class Error < StandardError
  end

  ACTIONS = %w[deny allow screen].freeze
  PERMISSIONS = %w[read write execute].freeze

  extend self

  def workspace
    policy_path = Workspace.policy_path
    raise Error, 'The workspace requires .devin/policy.yml' unless File.file?(policy_path)
    raise Error, 'Workspace policy must not be a symlink' if File.symlink?(policy_path)

    load(policy_path)
  end

  def load(policy_path)
    return Document.new([], []) unless policy_path && File.file?(policy_path)

    document(raw(policy_path), policy_path)
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

  def exempt_list(value, policy_path)
    return [] if value.nil?
    raise Error, "Policy except must be a list of profile names: #{policy_path}" unless value.is_a?(Array)

    value.map(&:to_s).reject(&:empty?)
  end

  private

  def raw(policy_path)
    parsed = YAML.safe_load(File.read(policy_path)) || {}
    raise Error, "Policy must be a map: #{policy_path}" unless parsed.is_a?(Hash)

    parsed
  end

  def document(parsed, policy_path)
    permissions = parsed['permissions']
    rules = parsed['rules']
    unless permissions.nil? || permissions.is_a?(Array)
      raise Error, "Policy permissions must be a list: #{policy_path}"
    end
    raise Error, "Policy rules must be a list: #{policy_path}" unless rules.nil? || rules.is_a?(Array)

    Document.new(
      Array(permissions).map { |entry| Grant.new(entry, policy_path) },
      Array(rules).map { |rule| Rule.new(rule, policy_path) }
    )
  end

  class Document
    def initialize(permissions, rules)
      @permissions = permissions
      @rules = rules
    end

    attr_reader :permissions, :rules

    def permits?(kind, profile_name)
      granted = false
      @permissions.each do |grant|
        next unless grant.default? || (!profile_name.to_s.empty? && grant.named?(profile_name))

        granted = true if grant.grants?(kind)
        granted = false if grant.revokes?(kind)
      end
      granted
    end
  end

  class Grant
    def initialize(value, policy_path)
      raise Error, "A policy permission must be a map: #{policy_path}" unless value.is_a?(Hash)
      unless value.keys.length == 1
        raise Error, "A policy permission names default or one profile: #{policy_path}"
      end

      @profile = value.key?('default') ? nil : value.keys.first.to_s
      if !value.key?('default') && @profile.empty?
        raise Error, "A policy permission needs a profile name: #{policy_path}"
      end

      @grants = []
      @revokes = []
      list = value.values.first
      raise Error, "Policy permissions must be a list: #{policy_path}" unless list.is_a?(Array)

      list.each do |entry|
        permission_name = entry.to_s
        revoke = permission_name.start_with?('-')
        permission_name = permission_name.delete_prefix('-')
        unless PERMISSIONS.include?(permission_name)
          raise Error, "Unknown policy permission: #{entry.inspect}"
        end

        (revoke ? @revokes : @grants) << permission_name
      end
    end

    def default?
      @profile.nil?
    end

    def named?(profile_name)
      !@profile.nil? && @profile.casecmp?(profile_name.to_s)
    end

    def grants?(kind)
      @grants.include?(kind)
    end

    def revokes?(kind)
      @revokes.include?(kind)
    end
  end

  class Rule
    def initialize(value, policy_path)
      raise Error, "A policy rule must be a map: #{policy_path}" unless value.is_a?(Hash)

      @action = value['action'].to_s
      raise Error, "Unknown policy action: #{@action.inspect}" unless ACTIONS.include?(@action)

      @question = question(value['question'])
      raise Error, "A screen rule needs a question: #{policy_path}" if screen? && @question.empty?

      @match = value['match'].is_a?(Hash) ? value['match'] : {}
      @except = Policy.exempt_list(value['except'], policy_path)
      @expose = value['expose']
      unless @expose.nil? || @expose.is_a?(Array)
        raise Error, "Policy expose must be a list of input fields: #{policy_path}"
      end

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
      !profile_name.to_s.empty? && @except.any? { |entry| entry.casecmp?(profile_name.to_s) }
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
