require 'yaml'

require_relative 'profile_store'
require_relative 'jev'

# A policy is an ordered list of rules that screen a tool call. Each rule
# matches on the tool name and any of the call's input fields, then either
# denies the call outright, allows it, or asks the backend a typed question and
# denies when the answer is harmful.
#
# The master policy (templates/policy.yml) screens every call. A room's own
# policy.yml adds rules on top, and can only restrict: composition never lets a
# later policy's allow outrank an earlier deny or screen, so a room owner
# cannot grant what the master forbids.
module Policy
  class Error < StandardError
  end

  MASTER_FILE = 'templates/policy.yml'
  DEFAULT_THRESHOLD = 0.5
  ACTIONS = %w[deny allow screen].freeze

  extend self

  def master_path
    File.join(ProfileStore.root, MASTER_FILE)
  end

  def master
    @master ||= load(master_path)
  end

  # Tests and long-lived processes reload when the master file may have changed.
  def reset!
    @master = nil
  end

  def load(path)
    return [] unless path && File.file?(path)

    parsed = YAML.safe_load(File.read(path))
    parsed = {} unless parsed.is_a?(Hash)
    rules = parsed['rules']
    raise Error, "Policy rules must be a list: #{path}" unless rules.nil? || rules.is_a?(Array)

    Array(rules).map { |rule| Rule.new(rule, path) }
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
    policies.flatten.compact.each do |rule|
      next unless rule.match?(request)
      return [true, rule.reason] if rule.deny?
      next unless rule.screen?
      return [true, rule.reason] if rule.harmful?(request, jev: jev)
    end

    [false, nil]
  end

  class Rule
    def initialize(raw, source)
      raise Error, "A policy rule must be a map: #{source}" unless raw.is_a?(Hash)

      @action = raw['action'].to_s
      raise Error, "Unknown policy action: #{@action.inspect}" unless ACTIONS.include?(@action)
      raise Error, "A screen rule needs a question: #{source}" if screen? && !raw['question'].is_a?(Hash)

      @match = raw['match'].is_a?(Hash) ? raw['match'] : {}
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

    # Every filter must match. `tool` is the tool name; any other key is an
    # input field, matched as a regular expression against its string value.
    def match?(request)
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
