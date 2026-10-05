require_relative '../mcp/protocol'
require_relative 'operations'

module Coord
  class Server
    INFO = { 'name' => 'autonom-coord', 'version' => '0.1.0' }.freeze

    include MCP::Protocol
    include Operations

    def run(input: STDIN, output: STDOUT)
      output.sync = true
      write_lock = Mutex.new
      workers = []
      input.each_line do |line|
        request = parse(line)
        # A blocking wait must not stall the requests behind it, so it runs on
        # its own thread. Everything else is answered in arrival order - a
        # client that sends set_profile then post_message must not see the two
        # race - and no worker outlives the process with its response unwritten.
        if waiting?(request)
          workers << Thread.new { respond(request, output, write_lock) }
        else
          respond(request, output, write_lock)
        end
      end
      workers.each(&:join)
    end

    private

    def waiting?(request)
      request.is_a?(Hash) && request['method'] == 'tools/call' &&
        request.dig('params', 'name') == 'wait_for_message'
    end
  end
end

Coord::Server.new.run if $PROGRAM_NAME == __FILE__
