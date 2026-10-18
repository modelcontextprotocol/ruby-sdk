# frozen_string_literal: true

require "json"

module JsonRpcHandler
  class Version
    V1_0 = "1.0"
    V2_0 = "2.0"
  end

  class ErrorCode
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603
    PARSE_ERROR = -32700
  end

  DEFAULT_ALLOWED_ID_CHARACTERS = /\A[a-zA-Z0-9_-]+\z/.freeze

  # Sentinel return value from a handler. When a handler returns this,
  # `process_request` emits no JSON-RPC response for the request,
  # matching the notification-style semantics (id is ignored).
  NO_RESPONSE = Object.new.freeze

  extend self

  def handle(request, id_validation_pattern: DEFAULT_ALLOWED_ID_CHARACTERS, &method_finder)
    if request.is_a?(Array)
      return error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INVALID_REQUEST,
        message: "Invalid Request",
        data: "Request is an empty array",
      }) if request.empty?

      # Handle batch requests
      responses = request.map { |req| process_request(req, id_validation_pattern: id_validation_pattern, &method_finder) }.compact

      # A single item is hoisted out of the array
      return responses.first if responses.one?

      # An empty array yields nil
      responses if responses.any?
    elsif request.is_a?(Hash)
      # Handle single request
      process_request(request, id_validation_pattern: id_validation_pattern, &method_finder)
    else
      error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INVALID_REQUEST,
        message: "Invalid Request",
        data: "Request must be an array or a hash",
      })
    end
  end

  def handle_json(request_json, id_validation_pattern: DEFAULT_ALLOWED_ID_CHARACTERS, &method_finder)
    begin
      request = JSON.parse(request_json, symbolize_names: true)
      response = handle(request, id_validation_pattern: id_validation_pattern, &method_finder)
    rescue JSON::ParserError
      response = error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::PARSE_ERROR,
        message: "Parse error",
        data: "Invalid JSON",
      })
    rescue StandardError
      # Last-resort guard so an unexpected handling error returns a JSON-RPC error
      # instead of escaping to the transport loop.
      response = error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INTERNAL_ERROR,
        message: "Internal error",
      })
    end

    response&.to_json
  end

  def process_request(request, id_validation_pattern:, &method_finder)
    # A batch element can be any JSON value; a non-object element cannot carry an id or a method,
    # so reject it before the `request[:id]` access below.
    unless request.is_a?(Hash)
      return error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INVALID_REQUEST,
        message: "Invalid Request",
        data: "Request must be an object",
      })
    end

    id = request[:id]

    error = if !valid_version?(request[:jsonrpc])
      "JSON-RPC version must be 2.0"
    elsif request.key?(:id) && id.nil?
      # JSON-RPC 2.0 allows a null id; MCP rules it out: a request carries a string or an integer id,
      # and a notification carries no id member at all. Refused rather than run as a notification,
      # since a sender that wrote an id meant to be answered.
      "Request ID must not be null"
    elsif !valid_id?(id, id_validation_pattern)
      if id_validation_pattern
        "Request ID must be a string matching the validation pattern, or an integer"
      else
        "Request ID must be a string or an integer"
      end
    elsif !valid_method_name?(request[:method])
      'Method name must be a string and not start with "rpc."'
    end

    # Per JSON-RPC 2.0 (Response object, `id`), the error response must carry
    # the same id as the request when the id could be detected. `error_response`
    # leaves the id out for ids that fail validation, and the `:unknown_id` sentinel
    # keeps a response (without an id) being emitted when the request carried no id at all.
    return error_response(id: id.nil? ? :unknown_id : id, id_validation_pattern: id_validation_pattern, error: {
      code: ErrorCode::INVALID_REQUEST,
      message: "Invalid Request",
      data: error,
    }) if error

    method_name = request[:method]
    params = request[:params]

    unless valid_params?(params)
      return error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INVALID_PARAMS,
        message: "Invalid params",
        data: "Method parameters must be an array or an object or null",
      })
    end

    begin
      method = method_finder.call(method_name, id)

      if method.nil?
        return error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
          code: ErrorCode::METHOD_NOT_FOUND,
          message: "Method not found",
          data: method_name,
        })
      end

      result = method.call(params)
      return if result.equal?(NO_RESPONSE)

      success_response(id: id, result: result)
    rescue MCP::Server::RequestHandlerError => e
      handle_request_error(e, id, id_validation_pattern)
    rescue StandardError
      # The exception message is deliberately not echoed into `data`: it can carry
      # internals that must not reach untrusted clients (CWE-209).
      error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INTERNAL_ERROR,
        message: "Internal error",
      })
    end
  end

  def handle_request_error(error, id, id_validation_pattern)
    if error.respond_to?(:error_code) && error.error_code
      code = error.error_code
      message = error.message
    else
      error_type = error.respond_to?(:error_type) ? error.error_type : nil

      code, message = case error_type
      when :invalid_request then [ErrorCode::INVALID_REQUEST, "Invalid Request"]
      when :invalid_params then [ErrorCode::INVALID_PARAMS, "Invalid params"]
      when :parse_error then [ErrorCode::PARSE_ERROR, "Parse error"]
      when :internal_error then [ErrorCode::INTERNAL_ERROR, "Internal error"]
      else [ErrorCode::INTERNAL_ERROR, "Internal error"]
      end
    end

    data = error.respond_to?(:error_data) && error.error_data ? error.error_data : error.message

    error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
      code: code,
      message: message,
      data: data,
    })
  end

  def valid_version?(version)
    version == Version::V2_0
  end

  def valid_id?(id, pattern = nil)
    return true if id.nil? || id.is_a?(Integer)
    # A string that is not valid in its encoding cannot be written into the response,
    # and matching a pattern against it raises, so it is refused before the method runs.
    return false unless id.is_a?(String) && id.valid_encoding?

    pattern ? id.match?(pattern) : true
  end

  def valid_method_name?(method)
    method.is_a?(String) && !method.start_with?("rpc.")
  end

  def valid_params?(params)
    params.nil? || params.is_a?(Array) || params.is_a?(Hash)
  end

  def success_response(id:, result:)
    {
      jsonrpc: Version::V2_0,
      id: id,
      result: result,
    } unless id.nil?
  end

  # An error response for a request whose id could not be read carries no `id` member: JSON-RPC 2.0 puts
  # a null there, but the MCP schema allows only a string or an integer, and the Streamable HTTP transport
  # specification describes such a body as an error response that has no id.
  def error_response(id:, id_validation_pattern:, error:)
    return if id.nil?

    response = { jsonrpc: Version::V2_0 }
    response[:id] = id if valid_id?(id, id_validation_pattern)
    response[:error] = error.compact
    response
  end
end
