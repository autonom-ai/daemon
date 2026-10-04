require 'json'
require 'open3'

module Gateway
  ENTRY = File.expand_path('../dist/gateway.js', __dir__)
  TIMEOUT = 15

  class Error < StandardError
  end

  extend self

  def call(request, timeout = TIMEOUT)
    raise Error, 'The AI gateway has not been built' unless File.file?(ENTRY)

    Open3.popen3('node', ENTRY) do |stdin, stdout, _stderr, waiter|
      stdin.write(JSON.generate(request))
      stdin.close
      unless waiter.join(timeout)
        Process.kill('TERM', waiter.pid)
        raise Error, 'The gateway request timed out'
      end
      raise Error, 'The gateway is unavailable' unless waiter.value.success?

      JSON.parse(stdout.read)
    end
  rescue JSON::ParserError, IOError, SystemCallError
    raise Error, 'The gateway is unavailable'
  end
end
