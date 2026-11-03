# frozen_string_literal: true

module MCP
  # The custom-header half of SEP-2243 (MCP 2026-07-28), shared by the client and the server transport: scanning a tool's `inputSchema`
  # for `x-mcp-header` declarations, encoding `tools/call` argument values into `Mcp-Param-{Name}` HTTP headers with
  # the `=?base64?...?=` sentinel for values that cannot ride as plain ASCII field values, decoding such headers, and checking that
  # the headers a request carries agree with the arguments in its body. Mirrors the TypeScript SDK's `mcpParamHeaders` codec;
  # the standard-header half (`Mcp-Method`, `Mcp-Name`) lives with the transports.
  #
  # https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http#custom-headers-from-tool-parameters
  module McpParamHeaders
    # The fixed prefix every custom-parameter header carries.
    HEADER_PREFIX = "Mcp-Param-"

    # The schema-extension property name a tool's `inputSchema` carries.
    X_MCP_HEADER_KEY = "x-mcp-header"

    # RFC 9110 Section 5.1 `token` syntax (`1*tchar`): rejects empty names, spaces,
    # control characters (including CR/LF), and the HTTP delimiters.
    RFC9110_TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/.freeze

    # The spec text admits `string`, `integer`, and `boolean`. `number` is also accepted because
    # the published conformance referee annotates `type: "number"` parameters and expects them mirrored;
    # the TypeScript SDK makes the same accommodation.
    PERMITTED_TYPES = ["string", "integer", "boolean", "number"].freeze

    # JSON Schema keywords the SEP-2243 static-reachability constraint excludes from the `properties`-only chain.
    # An `x-mcp-header` under any of these invalidates the tool definition rather than being silently ignored.
    NON_REACHABLE_SUBSCHEMA_KEYWORDS = [
      "items",
      "prefixItems",
      "contains",
      "additionalProperties",
      "unevaluatedProperties",
      "unevaluatedItems",
      "propertyNames",
      "patternProperties",
      "dependentSchemas",
      "oneOf",
      "anyOf",
      "allOf",
      "not",
      "if",
      "then",
      "else",
      "contentSchema",
      "$defs",
      "definitions",
    ].freeze

    # Keywords whose value maps names to subschemas rather than being one subschema or a list of them.
    OBJECT_VALUED_SUBSCHEMA_KEYWORDS = ["patternProperties", "dependentSchemas", "$defs", "definitions"].freeze

    # Integers beyond 2**53 - 1 lose precision in JSON number interchange, so they are not mirrored;
    # the TypeScript SDK refuses unsafe integers the same way.
    MAX_SAFE_INTEGER = (2**53) - 1

    BASE64_SENTINEL_PREFIX = "=?base64?"
    BASE64_SENTINEL_SUFFIX = "?="

    # The decimal numerals the numeric comparison of an integer or number declaration accepts from a header:
    # the rendering of an integer (`42`, `-7`), or one with a fraction, which the spec's SHOULD equates to the integer (`42.0`).
    # Anything else (`0x2a`, `1e3`, `042`, ` 42`) is compared as a string and so never agrees by accident.
    CANONICAL_DECIMAL = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze

    NUMERIC_TYPES = ["integer", "number"].freeze

    # The longest numeral the numeric comparison reads, which bounds the arbitrary-precision parsing a header can ask for.
    # A longer numeral is judged by byte equality alone: that still accepts the rendering a client mirrors,
    # however long (an integral double renders as its digits), and refuses every other spelling of the number.
    MAX_NUMERAL_BYTES = 64

    class << self
      # Scans a tool's `inputSchema` for `x-mcp-header` declarations and validates every constraint the spec places on them:
      #  RFC 9110 token names, case-insensitive uniqueness, primitive-typed declaring properties, and static reachability through
      # a chain of `properties` keys only. Returns `{ valid: true, declarations: [...] }` with each declaration `{ path:, header_name:, type: }`,
      # or `{ valid: false, reason: "..." }` on the first violation.
      def scan(input_schema)
        declarations = []
        fault = visit(input_schema, [], true, declarations, {})

        fault ? { valid: false, reason: fault } : { valid: true, declarations: declarations }
      end

      # Builds the `Mcp-Param-{Name}` headers for one `tools/call` from the scanned declarations and the call's `arguments`.
      # A `null` or absent value omits its header (the spec's MUST-omit rows); a non-primitive or non-representable value is
      # omitted rather than emitted malformed.
      def build(declarations, arguments)
        declarations.each_with_object({}) do |declaration, headers|
          value = value_at_path(arguments, declaration[:path])
          next if value.nil?

          string_value = primitive_to_string(value)
          next unless string_value

          encoded = begin
            encode_value(string_value)
          rescue EncodingError
            # A string that cannot be represented as UTF-8 (e.g. binary data) has no header representation;
            # omit it like the other non-representable values.
            next
          end

          headers["#{HEADER_PREFIX}#{declaration[:header_name]}"] = encoded
        end
      end

      # Converts a primitive argument to its header string per the spec's type-conversion rules: strings pass through,
      # booleans become lowercase `"true"` / `"false"`, and numbers become their decimal string.
      # `nil` means "not representable: do not emit a header".
      def primitive_to_string(value)
        case value
        when String
          value
        when true
          "true"
        when false
          "false"
        when Integer
          value.abs <= MAX_SAFE_INTEGER ? value.to_s : nil
        when Float
          return unless value.finite?

          # JSON has one number type: an integral float serializes without the fractional part,
          # matching the `String(42.0)` the JavaScript reference emits.
          value == value.truncate ? value.truncate.to_s : value.to_s
        end
      end

      # Encodes a header value per the spec's value-encoding rules: a safe plain-ASCII field value
      # passes through unchanged, everything else is wrapped as `=?base64?{base64-of-UTF-8}?=`.
      def encode_value(value)
        return value unless needs_base64?(value)

        "#{BASE64_SENTINEL_PREFIX}#{[value.encode(Encoding::UTF_8)].pack("m0")}#{BASE64_SENTINEL_SUFFIX}"
      end

      # Decodes an `Mcp-Param-{Name}` header value: one carrying the sentinel yields its payload decoded as UTF-8,
      # any other value is taken literally, as the spec's examples show. `nil` marks a value the server has to refuse rather
      # than compare: one holding a byte outside the field-value set (the spec's invalid characters; a conforming client
      # wraps such a value), or a sentinel whose payload is not canonical Base64 (padding, alphabet, trailing bits) or
      # not valid UTF-8, since a lenient decoder would let two different header values stand for one body value.
      def decode_value(value)
        return unless field_value?(value)
        return value unless sentinel_wrapped?(value)

        payload_size = value.bytesize - BASE64_SENTINEL_PREFIX.bytesize - BASE64_SENTINEL_SUFFIX.bytesize
        decoded = value.byteslice(BASE64_SENTINEL_PREFIX.bytesize, payload_size).unpack1("m0").force_encoding(Encoding::UTF_8)
        decoded.valid_encoding? ? decoded : nil
      rescue ArgumentError
        nil
      end

      # The server side of the spec's table for custom headers: for each declaration, the `Mcp-Param-{Name}` header and
      # the body value at the declared path are present together and agree once the header is decoded, or are absent together.
      # The block is called with each declared header name and returns the raw field value, or `nil` when the request
      # does not carry it. Returns a message naming the first disagreement by header and argument path, never by value,
      # or `nil` when every declaration agrees.
      def mismatch(declarations, arguments)
        declarations.each do |declaration|
          header_name = "#{HEADER_PREFIX}#{declaration[:header_name]}"
          raw = yield(header_name)
          value = value_at_path(arguments, declaration[:path])
          argument = declaration[:path].join(".")

          if value.nil?
            # The spec has the server expect no header for a null or absent value. One sent anyway claims a value
            # the body does not carry, which is exactly what an intermediary acting on the header would act on.
            return "#{header_name} header is present but the request body carries no `#{argument}` argument" if raw

            next
          end

          rendered = primitive_to_string(value)
          if rendered.nil?
            # A value without a header rendering (an object, an array, an integer past the safe range) is one
            # a conforming client omits the header for, so a header claiming it can never agree with it.
            return "#{header_name} header does not match the `#{argument}` argument" if raw

            next
          end

          return "#{header_name} header is missing but the request body carries a `#{argument}` argument" if raw.nil?
          return "#{header_name} header holds a character that is not allowed in a field value" unless field_value?(raw)

          decoded = decode_value(raw)
          return "#{header_name} header carries a malformed Base64 value" if decoded.nil?

          unless agrees?(declaration[:type], value, rendered, decoded)
            return "#{header_name} header does not match the `#{argument}` argument"
          end
        end

        nil
      end

      private

      # A decoded header agrees with a body value when it equals the value's header rendering byte for byte, or, for
      # an integer or number declaration with a numeric body value, when it is a canonical decimal of the same number
      # within `MAX_NUMERAL_BYTES`: the spec's SHOULD that `42.0` equals `42`. An integer compares exactly, so a value
      # past the double range still compares; a float compares as the double the header denotes.
      def agrees?(type, value, rendered, decoded)
        return true if decoded.b == rendered.b
        return false unless NUMERIC_TYPES.include?(type) && value.is_a?(Numeric)
        return false unless decoded.bytesize <= MAX_NUMERAL_BYTES && CANONICAL_DECIMAL.match?(decoded)

        value.is_a?(Integer) ? Rational(decoded) == value : Float(decoded) == value
      end

      def visit(node, path, reachable, declarations, seen_lower)
        return unless node.is_a?(Hash)

        if key?(node, X_MCP_HEADER_KEY)
          fault = validate_declaration(node, path, reachable, declarations, seen_lower)

          return fault if fault
        end

        properties = read(node, "properties")
        if properties.is_a?(Hash)
          properties.each do |key, child|
            fault = visit(child, path + [key.to_s], reachable, declarations, seen_lower)

            return fault if fault
          end
        end

        # Static-reachability sweep: descend the keywords the `properties` chain MUST NOT pass through with `reachable: false`,
        # so an annotation under any of them is reported. `$defs` covers `$ref`-within-`$defs`; chasing arbitrary `$ref` URIs
        # is out of scope.
        NON_REACHABLE_SUBSCHEMA_KEYWORDS.each do |keyword|
          next unless (sub = read(node, keyword))

          branches = if sub.is_a?(Array)
            sub
          elsif sub.is_a?(Hash) && OBJECT_VALUED_SUBSCHEMA_KEYWORDS.include?(keyword)
            sub.values
          else
            [sub]
          end

          branches.each do |branch|
            fault = visit(branch, path + ["<#{keyword}>"], false, declarations, seen_lower)

            return fault if fault
          end
        end

        nil
      end

      def validate_declaration(node, path, reachable, declarations, seen_lower)
        if !reachable || path.empty?
          return "#{path_name(path)}: x-mcp-header is only permitted on properties statically reachable via a chain of `properties` keys"
        end

        annotation = read(node, X_MCP_HEADER_KEY)

        unless annotation.is_a?(String) && !annotation.empty?
          return "#{path_name(path)}: x-mcp-header MUST be a non-empty string"
        end

        unless RFC9110_TOKEN.match?(annotation)
          return "#{path_name(path)}: x-mcp-header `#{annotation}` is not a valid RFC 9110 token"
        end

        type = read(node, "type")
        unless type.is_a?(String) && PERMITTED_TYPES.include?(type)
          return "#{path_name(path)}: x-mcp-header is only permitted on primitive-typed properties (got `#{type.inspect}`)"
        end

        lower = annotation.downcase
        prior = seen_lower[lower]
        if prior
          return "x-mcp-header `#{annotation}` is not case-insensitively unique (also declared as `#{prior}`)"
        end

        seen_lower[lower] = annotation
        declarations << { path: path, header_name: annotation, type: type }
        nil
      end

      # A value cannot ride as a plain ASCII field value when it is empty, already shaped like the Base64 sentinel
      # (the spec's ambiguity rule), carries edge whitespace that field parsing would strip, or contains
      # a byte outside visible ASCII plus interior tab.
      def needs_base64?(value)
        return true if value.empty?
        return true if value.start_with?(BASE64_SENTINEL_PREFIX) && value.end_with?(BASE64_SENTINEL_SUFFIX)
        return true if value != value.strip

        !field_value?(value)
      end

      def sentinel_wrapped?(value)
        return false if value.bytesize < BASE64_SENTINEL_PREFIX.bytesize + BASE64_SENTINEL_SUFFIX.bytesize

        value.start_with?(BASE64_SENTINEL_PREFIX) && value.end_with?(BASE64_SENTINEL_SUFFIX)
      end

      # The bytes RFC 9110 lets a field value carry, which the spec's value encoding keeps a plain header within:
      # visible ASCII, space, and horizontal tab. Checked byte by byte, so a value of any encoding is judged the same.
      def field_value?(value)
        value.each_byte.all? { |byte| byte == 0x09 || byte.between?(0x20, 0x7e) }
      end

      def value_at_path(root, path)
        path.reduce(root) do |node, key|
          break unless node.is_a?(Hash)

          read(node, key)
        end
      end

      # Schemas and arguments arrive with string keys off the wire but may carry symbol keys when constructed in Ruby;
      # read both forms like the SDK's other readers.
      def read(hash, key)
        value = hash[key]

        value.nil? ? hash[key.to_sym] : value
      end

      def key?(hash, key)
        hash.key?(key) || hash.key?(key.to_sym)
      end

      def path_name(path)
        path.empty? ? "<root>" : path.join(".")
      end
    end
  end
end
