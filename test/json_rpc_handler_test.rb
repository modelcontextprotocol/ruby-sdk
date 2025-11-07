# frozen_string_literal: true

require "test_helper"

describe JsonRpcHandler do
  before do
    @registry = {}
    @response = nil
    @response_json = nil
  end

  describe "#handle" do
    # Comments verbatim from https://www.jsonrpc.org/specification
    #
    # JSON-RPC 2.0 Specification
    #
    # 1 Overview
    # ...
    # 2 Conventions
    # ...
    # 3 Compatibility
    # ...
    # 4 Request object
    #
    # A rpc call is represented by sending a Request object to a Server. The Request object has the following members:
    #
    # jsonrpc
    #   A String specifying the version of the JSON-RPC protocol. MUST be exactly "2.0".

    it "returns a result when jsonrpc is 2.0" do
      register("add") { |params| params[:a] + params[:b] }

      handle jsonrpc: "2.0", id: 1, method: "add", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
    end

    it "returns an error when jsonrpc is not 2.0" do
      handle jsonrpc: "3.0", id: 1, method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "JSON-RPC version must be 2.0",
      }
    end

    # method
    #   A String containing the name of the method to be invoked. Method names that begin with the word rpc followed by
    #   a period character (U+002E or ASCII 46) are reserved for rpc-internal methods and extensions and MUST NOT be
    #   used for anything else.

    it "returns an error when method is not a string" do
      handle jsonrpc: "2.0", id: 1, method: 42, params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: 'Method name must be a string and not start with "rpc."',
      }
    end

    it "returns an error when method begins with 'rpc.'" do
      handle jsonrpc: "2.0", id: 1, method: "rpc.add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: 'Method name must be a string and not start with "rpc."',
      }
    end

    # params
    #   A Structured value that holds the parameter values to be used during the invocation of the method. This member
    #   MAY be omitted.

    it "returns a result when parameters are omitted" do
      register("greet") { "Hello, world!" }

      handle jsonrpc: "2.0", id: 1, method: "greet"

      assert_rpc_success expected_result: "Hello, world!"
    end

    # id
    #   An identifier established by the Client that MUST contain a String, Number, or NULL value if included. If it is
    #   not included it is assumed to be a notification. The value SHOULD normally not be Null and Numbers SHOULD NOT
    #   contain fractional parts.
    #
    #   The Server MUST reply with the same value in the Response object if included. This member is used to correlate the
    #   context between the two objects.

    it "returns a response with the same request id when the id is a valid string" do
      register("add") { |params| params[:a] + params[:b] }
      id = "request-123_abc"

      handle jsonrpc: "2.0", id:, method: "add", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
      assert_equal id, @response[:id]
    end

    it "returns a response with the same request id when the id is an integer" do
      register("add") { |params| params[:a] + params[:b] }
      id = 42

      handle jsonrpc: "2.0", id:, method: "add", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
      assert_equal id, @response[:id]
    end

    it "returns an error when request id is not of a valid type" do
      handle jsonrpc: "2.0", id: true, method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    it "accepts string id with alphanumerics, dashes, and underscores" do
      register("add") { |params| params[:a] + params[:b] }
      id = "request-123_ABC"

      handle jsonrpc: "2.0", id:, method: "add", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
      assert_equal id, @response[:id]
    end

    it "accepts UUID format strings" do
      register("add") { |params| params[:a] + params[:b] }
      id = "550e8400-e29b-41d4-a716-446655440000"

      handle jsonrpc: "2.0", id:, method: "add", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
      assert_equal id, @response[:id]
    end

    it "returns an error when request id contains HTML content (XSS prevention)" do
      handle jsonrpc: "2.0", id: "<script>alert('xss')</script>", method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    it "returns an error when request id contains spaces" do
      handle jsonrpc: "2.0", id: "request 123", method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    it "returns an error when request id contains special characters" do
      handle jsonrpc: "2.0", id: "request@123", method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    it "returns an error when request id is an empty string" do
      handle jsonrpc: "2.0", id: "", method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    it "returns an error when id is a number with a fractional part" do
      handle jsonrpc: "2.0", id: 3.14, method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
    end

    # 4.1 Notification
    #
    # A Notification is a Request object without an "id" member. A Request object that is a Notification signifies the
    # Client's lack of interest in the corresponding Response object, and as such no Response object needs to be
    # returned to the client. The Server MUST NOT reply to a Notification, including those that are within a batch
    # request.
    #
    # Notifications are not confirmable by definition, since they do not have a Response object to be returned. As such,
    # the Client would not be aware of any errors (like e.g. "Invalid params","Internal error").

    describe "with a notification request" do
      it "returns nil even if the method returns a result" do
        register("ping") { "pong" }

        handle jsonrpc: "2.0", method: "ping"

        assert_nil @response
      end

      it "returns nil even if the method raises an error" do
        register("ping") { raise StandardError, "Something bad happened" }

        handle jsonrpc: "2.0", method: "ping"

        assert_nil @response
      end
    end

    # 4.2 Parameter Structures
    #
    # If present, parameters for the rpc call MUST be provided as a Structured value. Either by-position through an
    # Array or by-name through an Object.
    #
    # * by-position: params MUST be an Array, containing the values in the Server expected order.
    # * by-name: params MUST be an Object, with member names that match the Server expected parameter names. The absence
    #   of expected names MAY result in an error being generated. The names MUST match exactly, including case, to the
    #   method's expected parameters.

    it "with array params returns a result" do
      register("sum", &:sum)

      handle jsonrpc: "2.0", id: 1, method: "sum", params: [1, 2, 3]

      assert_rpc_success expected_result: 6
    end

    it "with hash params returns a result" do
      register("sum") { |params| params[:a] + params[:b] }

      handle jsonrpc: "2.0", id: 1, method: "sum", params: { a: 1, b: 2 }

      assert_rpc_success expected_result: 3
    end

    # 5 Response object
    #
    # When a rpc call is made, the Server MUST reply with a Response, except for in the case of Notifications. The
    # Response is expressed as a single JSON Object, with the following members:

    # jsonrpc
    #   A String specifying the version of the JSON-RPC protocol. MUST be exactly "2.0".

    it "returns a result with jsonrpc set to 2.0" do
      register("add") { |params| params[:a] + params[:b] }

      handle jsonrpc: "2.0", id: 1, method: "add", params: { a: 1, b: 2 }

      assert_equal "2.0", @response[:jsonrpc]
    end

    # result
    #   This member is REQUIRED on success.
    #   This member MUST NOT exist if there was an error invoking the method.
    #   The value of this member is determined by the method invoked on the Server.
    #
    # error
    #   This member is REQUIRED on error.
    #   This member MUST NOT exist if there was no error triggered during invocation.
    #   The value for this member MUST be an Object as defined in section 5.1.
    #
    # id
    #   This member is REQUIRED.
    #   It MUST be the same as the value of the id member in the Request Object.
    #   If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be
    #   Null.
    #
    # Either the result member or error member MUST be included, but both members MUST NOT be included.

    it "returns a result object and no error object on success" do
      register("ping") { "pong" }

      handle jsonrpc: "2.0", id: 1, method: "ping"

      assert_rpc_success expected_result: "pong"
      assert_equal 1, @response[:id]
      assert_nil @response[:error]
    end

    it "returns an error object and no result object on error" do
      register("ping") { raise StandardError, "Something bad happened" }

      handle jsonrpc: "2.0", id: 1, method: "ping"

      assert_rpc_error expected_error: {
        code: -32603,
        message: "Internal error",
        data: "Something bad happened",
      }
      assert_equal 1, @response[:id]
      assert_nil @response[:result]
    end

    it "returns nil for id when there is an error and and error detecting the id" do
      register("ping") { "pong" }

      handle jsonrpc: "2.0", id: {}, method: "ping"

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request ID must match validation pattern, or be an integer or null",
      }
      assert_nil @response[:id]
    end

    # 5.1 Error object
    #
    # When a rpc call encounters an error, the Response Object MUST contain the error member with a value that is a
    # Object with the following members:
    #
    # code
    #   A Number that indicates the error type that occurred.
    #   This MUST be an integer.
    # message
    #   A String providing a short description of the error.
    #   The message SHOULD be limited to a concise single sentence.
    # data
    #   A Primitive or Structured value that contains additional information about the error.
    #   This may be omitted.
    #   The value of this member is defined by the Server (e.g. detailed error information, nested errors etc.).
    #
    # | code   | message          | meaning                                       |
    # | ------ | ---------------- | --------------------------------------------- |
    # | -32700 | Parse error      | Invalid JSON was received by the server.      |
    # | -32600 | Invalid Request  | The JSON sent is not a valid Request object.  |
    # | -32601 | Method not found | The method does not exist / is not available. |
    # | -32602 | Invalid params   | Invalid method parameter(s).                  |
    # | -32603 | Internal error   | Internal JSON-RPC error.                      |

    it "returns an error with the code set to -32700 there is a JSON parse error" do
      # Defer to handle_json for JSON parsing
      handle_json "Invalid JSON"

      assert_rpc_error expected_error: {
        code: -32700,
        message: "Parse error",
        data: "Invalid JSON",
      }
    end

    it "returns an error with code set to -32600 when the request is not an array or a hash" do
      handle true

      assert_rpc_error expected_error: {
        code: -32600,
        message: "Invalid Request",
        data: "Request must be an array or a hash",
      }
    end

    it "returns an error with the code set to -32601 when the method does not exist" do
      handle jsonrpc: "2.0", id: 1, method: "add", params: { a: 1, b: 2 }

      assert_rpc_error expected_error: {
        code: -32601,
        message: "Method not found",
        data: "add",
      }
    end

    it "returns nil when the method does not exist and the id is nil" do
      handle jsonrpc: "2.0", method: "add", params: { a: 1, b: 2 }

      assert_nil @response
    end

    it "returns an error with the code set to -32602 when the method parameters are invalid" do
      handle jsonrpc: "2.0", id: 1, method: "set_active", params: true

      assert_rpc_error expected_error: {
        code: -32602,
        message: "Invalid params",
        data: "Method parameters must be an array or an object or null",
      }
    end

    it "returns an error with the code set to -32603 when there is an internal error" do
      register("add") { raise StandardError, "Something bad happened" }

      handle jsonrpc: "2.0", id: 1, method: "add"

      assert_rpc_error expected_error: {
        code: -32603,
        message: "Internal error",
        data: "Something bad happened",
      }
    end

    # 6 Batch
    #
    # To send several Request objects at the same time, the Client MAY send an Array filled with Request objects.
    #
    # The Server should respond with an Array containing the corresponding Response objects, after all of the batch
    # Request objects have been processed. A Response object SHOULD exist for each Request object, except that there
    # SHOULD NOT be any Response objects for notifications. The Server MAY process a batch rpc call as a set of
    # concurrent tasks, processing them in any order and with any width of parallelism.
    #
    # The Response objects being returned from a batch call MAY be returned in any order within the Array. The Client
    # SHOULD match contexts between the set of Request objects and the resulting set of Response objects based on the id
    # member within each Object.
    #
    # If the batch rpc call itself fails to be recognized as an valid JSON or as an Array with at least one value, the
    # response from the Server MUST be a single Response object. If there are no Response objects contained within the
    # Response array as it is to be sent to the client, the server MUST NOT return an empty Array and should return
    # nothing at all.

    describe "with batch request" do
      it "returns an invalid request error when the request is an empty array" do
        handle []

        assert_rpc_error expected_error: {
          code: -32600,
          message: "Invalid Request",
          data: "Request is an empty array",
        }
      end

      it "returns an array of Response objects" do
        register("add") { |params| params[:a] + params[:b] }
        register("mul") { |params| params[:a] * params[:b] }

        handle [
          { jsonrpc: "2.0", id: 100, method: "add", params: { a: 1, b: 2 } },
          { jsonrpc: "2.0", id: 200, method: "mul", params: { a: 3, b: 4 } },
        ]

        assert @response.is_a?(Array)
        assert @response.all? { |result| result[:jsonrpc] == "2.0" }
        assert_equal [100, 200], @response.map { |result| result[:id] }
        assert_equal [3, 12], @response.map { |result| result[:result] }
        assert @response.all? { |result| result[:error].nil? }
      end

      it "returns an array of Response objects excluding notifications" do
        register("ping") {}
        register("add") { |params| params[:a] + params[:b] }

        handle [
          { jsonrpc: "2.0", method: "ping" },
          { jsonrpc: "2.0", id: 100, method: "add", params: { a: 1, b: 2 } },
          { jsonrpc: "2.0", id: 200, method: "add", params: { a: 2, b: 3 } },
        ]

        assert @response.is_a?(Array)
        assert @response.all? { |result| result[:jsonrpc] == "2.0" }
        assert_equal [100, 200], @response.map { |result| result[:id] }
        assert_equal [3, 5], @response.map { |result| result[:result] }
        assert @response.all? { |result| result[:error].nil? }
      end

      it "returns a single response object when the batch has only a single response" do
        register("ping") {}
        register("add") { |params| params[:a] + params[:b] }

        handle [
          { jsonrpc: "2.0", method: "ping" },
          { jsonrpc: "2.0", id: 100, method: "add", params: { a: 1, b: 2 } },
        ]

        assert_rpc_success expected_result: 3
      end

      it "returns nil when the batch has only notifications" do
        register("ping") {}
        register("pong") {}

        handle [
          { jsonrpc: "2.0", method: "ping" },
          { jsonrpc: "2.0", method: "pong" },
        ]

        assert_nil @response
      end
    end

    # 7 Examples
    # ...
    # 8 Extensions
    #
    # Method names that begin with rpc. are reserved for system extensions, and MUST NOT be used for anything else. Each
    # system extension is defined in a related specification. All system extensions are OPTIONAL.

    describe "ID pattern configuration" do
      it "uses the default pattern by default" do
        register("add") { |params| params[:a] + params[:b] }

        handle jsonrpc: "2.0", id: "valid-id_123", method: "add", params: { a: 1, b: 2 }

        assert_rpc_success expected_result: 3
      end

      it "rejects IDs that don't match the default pattern" do
        handle jsonrpc: "2.0", id: "invalid@id", method: "add", params: { a: 1, b: 2 }

        assert_rpc_error expected_error: {
          code: -32600,
          message: "Invalid Request",
          data: "Request ID must match validation pattern, or be an integer or null",
        }
      end

      it "uses default pattern and rejects @ signs" do
        register("add") { |params| params[:a] + params[:b] }

        # Default pattern should reject @ signs
        handle jsonrpc: "2.0", id: "user@example.com", method: "add", params: { a: 1, b: 2 }

        assert_rpc_error expected_error: {
          code: -32600,
          message: "Invalid Request",
          data: "Request ID must match validation pattern, or be an integer or null",
        }
      end

      it "accepts custom pattern as parameter to handle" do
        register("add") { |params| params[:a] + params[:b] }
        custom_pattern = /\A[a-zA-Z0-9_.\-@]+\z/

        @response = JsonRpcHandler.handle(
          { jsonrpc: "2.0", id: "user@example.com", method: "add", params: { a: 1, b: 2 } },
          id_validation_pattern: custom_pattern,
        ) { |method_name| @registry[method_name] }

        assert_rpc_success expected_result: 3
        assert_equal "user@example.com", @response[:id]
      end

      it "validates against custom pattern parameter" do
        custom_pattern = /\A[a-zA-Z0-9_.\-@]+\z/

        @response = JsonRpcHandler.handle(
          { jsonrpc: "2.0", id: "id<script>", method: "add", params: { a: 1, b: 2 } },
          id_validation_pattern: custom_pattern,
        ) { |method_name| @registry[method_name] }

        assert_rpc_error expected_error: {
          code: -32600,
          message: "Invalid Request",
          data: "Request ID must match validation pattern, or be an integer or null",
        }
      end

      it "accepts custom pattern as parameter to handle_json" do
        register("add") { |params| params[:a] + params[:b] }
        custom_pattern = /\A[a-zA-Z0-9_.\-@]+\z/

        @response_json = JsonRpcHandler.handle_json(
          { jsonrpc: "2.0", id: "user@example.com", method: "add", params: { a: 1, b: 2 } }.to_json,
          id_validation_pattern: custom_pattern,
        ) { |method_name| @registry[method_name] }
        @response = JSON.parse(@response_json, symbolize_names: true)

        assert_rpc_success expected_result: 3
        assert_equal "user@example.com", @response[:id]
      end

      it "applies custom pattern to batch requests" do
        register("add") { |params| params[:a] + params[:b] }
        register("mul") { |params| params[:a] * params[:b] }
        custom_pattern = /\A[a-zA-Z0-9_.\-@]+\z/

        @response = JsonRpcHandler.handle(
          [
            { jsonrpc: "2.0", id: "req@1", method: "add", params: { a: 1, b: 2 } },
            { jsonrpc: "2.0", id: "req@2", method: "mul", params: { a: 3, b: 4 } },
          ],
          id_validation_pattern: custom_pattern,
        ) { |method_name| @registry[method_name] }

        assert @response.is_a?(Array)
        assert_equal ["req@1", "req@2"], @response.map { |r| r[:id] }
        assert_equal [3, 12], @response.map { |r| r[:result] }
      end

      it "parameter pattern overrides default pattern" do
        register("add") { |params| params[:a] + params[:b] }
        # Use permissive parameter pattern (default is restrictive)
        custom_pattern = /\A[a-zA-Z0-9_.\-@]+\z/

        @response = JsonRpcHandler.handle(
          { jsonrpc: "2.0", id: "user@example.com", method: "add", params: { a: 1, b: 2 } },
          id_validation_pattern: custom_pattern,
        ) { |method_name| @registry[method_name] }

        assert_rpc_success expected_result: 3
        assert_equal "user@example.com", @response[:id]
      end

      it "accepts any string when pattern is nil" do
        register("add") { |params| params[:a] + params[:b] }

        @response = JsonRpcHandler.handle(
          { jsonrpc: "2.0", id: "<script>alert('xss')</script>", method: "add", params: { a: 1, b: 2 } },
          id_validation_pattern: nil,
        ) { |method_name| @registry[method_name] }

        assert_rpc_success expected_result: 3
        assert_equal "<script>alert('xss')</script>", @response[:id]
      end
    end
  end

  describe "#handle_json" do
    it "returns a Response object when the request is valid and not a notification" do
      register("add") { |params| params[:a] + params[:b] }

      handle_json({ jsonrpc: "2.0", id: 1, method: "add", params: { a: 1, b: 2 } }.to_json)

      assert_rpc_success(expected_result: 3)
    end

    it "returns nil for notifications" do
      register("ping") {}

      handle_json({ jsonrpc: "2.0", method: "ping" }.to_json)

      assert_nil @response
    end

    it "returns an error with the id set to nil when the request is invalid" do
      handle_json({ jsonrpc: "0.0", id: 1, method: "add", params: { a: 1, b: 2 } }.to_json)

      assert_nil @response[:id]
    end
  end

  private

  def register(method_name, &block)
    @registry[method_name] = block
  end

  def handle(request)
    @response = JsonRpcHandler.handle(request) { |method_name| @registry[method_name] }
  end

  def handle_json(request_json)
    @response_json = JsonRpcHandler.handle_json(request_json) { |method_name| @registry[method_name] }
    @response = JSON.parse(@response_json, symbolize_names: true) if @response_json
  end

  def assert_rpc_success(expected_result:)
    assert_equal(expected_result, @response[:result])
    assert_nil(@response[:error])
  end

  def assert_rpc_error(expected_error:)
    assert_equal(expected_error, @response[:error])
    assert_nil(@response[:result])
  end
end
