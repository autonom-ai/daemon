require 'json'

module MCP
  module Protocol
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    DEFAULT_PROTOCOL = '2025-03-26'

    private

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def respond(request, output, write_lock = nil)
      response = request ? handle(request) : error(nil, -32700, 'Parse error')
      write_response(response, output, write_lock) if response
    rescue StandardError
      id = request.is_a?(Hash) ? request['id'] : nil
      write_response(error(id, -32603, 'Internal error'), output, write_lock)
    end

    def handle(request)
      return error(nil, -32600, 'Invalid request') unless request.is_a?(Hash)

      id = request['id']
      method = request['method']
      params = request['params'].is_a?(Hash) ? request['params'] : {}
      return nil if method == 'notifications/initialized' || method == 'notifications/cancelled'
      return error(id, -32600, 'Invalid request') unless method.is_a?(String)

      case method
      when 'initialize'
        protocol = params['protocolVersion']
        protocol = DEFAULT_PROTOCOL unless PROTOCOLS.include?(protocol)
        success(
          id,
          'protocolVersion' => protocol,
          'capabilities' => { 'tools' => { 'listChanged' => false } },
          'serverInfo' => self.class.const_get(:INFO)
        )
      when 'ping'
        success(id, {})
      when 'tools/list'
        success(id, 'tools' => tools)
      when 'tools/call'
        success(id, call_tool(params))
      else
        error(id, -32601, 'Method not found')
      end
    end

    def write_response(response, output, write_lock)
      write = -> { output.puts(JSON.generate(response)) }
      write_lock ? write_lock.synchronize(&write) : write.call
    end

    def success(id, ret)
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => ret }
    end

    def error(id, code, message)
      { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } }
    end

    def tool_error(message)
      { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true }
    end
  end
end
