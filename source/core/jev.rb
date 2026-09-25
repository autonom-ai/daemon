require_relative 'jev/common'
require_relative 'jev/openjev'
require_relative 'jev/typesafe'
require_relative 'jev/decider'

module JEV
  class Error < StandardError
  end

  DEFAULT = 'openjev'

  # The interchangeable backends: each takes a state and typed questions and
  # returns an answers map, and they differ in who runs the model and who sees
  # the request.
  BACKENDS = { 'openjev' => OpenJEV, 'typesafe' => TypeSafe, 'decider' => Decider }.freeze

  extend self

  def backend
    @backend ||= BACKENDS.fetch(DEFAULT)
  end

  def backend=(name)
    @backend = BACKENDS.fetch(name.to_s.downcase) { raise Error, "Unknown JEV backend: #{name}" }
  end

  # A state plus typed questions in, an answers map out.
  def decide(state, questions)
    backend.decide(state, questions)
  end
end
