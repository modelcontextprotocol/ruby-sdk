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

  DEFAULT_ALLOWED_ID_CHARACTERS = /\A[a-zA-Z0-9_-]+\z/

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
    end

    response&.to_json
  end

  def process_request(request, id_validation_pattern:, &method_finder)
    id = request[:id]

    error = if !valid_version?(request[:jsonrpc])
      "JSON-RPC version must be 2.0"
    elsif !valid_id?(request[:id], id_validation_pattern)
      "Request ID must match validation pattern, or be an integer or null"
    elsif !valid_method_name?(request[:method])
      'Method name must be a string and not start with "rpc."'
    end

    return error_response(id: :unknown_id, id_validation_pattern: id_validation_pattern, error: {
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
      method = method_finder.call(method_name)

      if method.nil?
        return error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
          code: ErrorCode::METHOD_NOT_FOUND,
          message: "Method not found",
          data: method_name,
        })
      end

      result = method.call(params)

      success_response(id: id, result: result)
    rescue MCP::Server::RequestHandlerError => e
      handle_request_error(e, id, id_validation_pattern)
    rescue StandardError => e
      error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
        code: ErrorCode::INTERNAL_ERROR,
        message: "Internal error",
        data: e.message,
      })
    end
  end

  def handle_request_error(error, id, id_validation_pattern)
    error_type = error.respond_to?(:error_type) ? error.error_type : nil

    code, message = case error_type
    when :invalid_request then [ErrorCode::INVALID_REQUEST, "Invalid Request"]
    when :invalid_params then [ErrorCode::INVALID_PARAMS, "Invalid params"]
    when :parse_error then [ErrorCode::PARSE_ERROR, "Parse error"]
    when :internal_error then [ErrorCode::INTERNAL_ERROR, "Internal error"]
    else [ErrorCode::INTERNAL_ERROR, "Internal error"]
    end

    error_response(id: id, id_validation_pattern: id_validation_pattern, error: {
      code: code,
      message: message,
      data: error.message,
    })
  end

  def valid_version?(version)
    version == Version::V2_0
  end

  def valid_id?(id, pattern = nil)
    return true if id.nil? || id.is_a?(Integer)
    return false unless id.is_a?(String)

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

  def error_response(id:, id_validation_pattern:, error:)
    {
      jsonrpc: Version::V2_0,
      id: valid_id?(id, id_validation_pattern) ? id : nil,
      error: error.compact,
    } unless id.nil?
  end
end
