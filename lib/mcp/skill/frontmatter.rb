# frozen_string_literal: true

require "psych"

module MCP
  class Skill
    # Reads and compares the YAML frontmatter of a `SKILL.md`, the same way on the server (where
    # `from_directory` publishes it) and on the client (where a host compares what it fetched with the entry
    # it holds, a SEP-2640 MUST). The rules are stricter than YAML so that every YAML library reads the block
    # the same way: one document, no directives or document markers, no tags, no aliases or merge keys, keys
    # that are untagged Strings, and no plain scalar whose YAML 1.1 reading (Psych's) differs from its
    # YAML 1.2 core-schema reading (the JavaScript and Go libraries'); such a value is written quoted instead.
    # Values must be JSON-representable because the entry travels as JSON.
    module Frontmatter
      extend self

      # Raised internally with `reason` `:parse` (the block cannot be read under these rules) or `:frontmatter`
      # (it reads fine but differs from the entry); callers translate it into their own error types.
      class Error < StandardError
        attr_reader :reason

        def initialize(reason, message = "frontmatter #{reason}")
          super(message)
          @reason = reason
        end
      end

      BOM = "\xEF\xBB\xBF".b.freeze
      DELIMITER = "---"
      # NEL, LINE SEPARATOR, and PARAGRAPH SEPARATOR: line breaks in YAML 1.1 (Psych) but not in YAML 1.2.
      UNICODE_BREAKS = Regexp.union([0x85, 0x2028, 0x2029].map { |codepoint| codepoint.chr(Encoding::UTF_8) }).freeze
      MERGE_KEY = "<<"
      # An SDK loading limit for the frontmatter block, not a protocol rule: the file itself may be 16 MiB.
      MAX_BLOCK_BYTES = 64 * 1024
      MAX_DEPTH = 64

      # Resolves plain scalars by the YAML 1.2 core schema, to compare with Psych's YAML 1.1 resolution.
      module CoreSchema
        extend self

        NULL = /\A(?:null|Null|NULL|~)?\z/.freeze
        TRUE = /\A(?:true|True|TRUE)\z/.freeze
        FALSE = /\A(?:false|False|FALSE)\z/.freeze
        INT10 = /\A[-+]?[0-9]+\z/.freeze
        INT8 = /\A0o[0-7]+\z/.freeze
        INT16 = /\A0x[0-9a-fA-F]+\z/.freeze
        FLOAT = /\A[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?\z/.freeze
        INF = /\A[-+]?\.(?:inf|Inf|INF)\z/.freeze
        NAN = /\A\.(?:nan|NaN|NAN)\z/.freeze

        def resolve(text)
          case text
          when NULL then nil
          when TRUE then true
          when FALSE then false
          when INT10 then Integer(text, 10)
          when INT8 then text[2..-1].to_i(8)
          when INT16 then text[2..-1].to_i(16)
          when INF then text.start_with?("-") ? -Float::INFINITY : Float::INFINITY
          when NAN then Float::NAN
          # Ruby's Float() rejects a trailing dot, which the core schema allows.
          when FLOAT then Float(text.sub(/\.(?=[eE]|\z)/, ".0"))
          else text
          end
        end

        # Whether Psych's reading of a plain scalar differs in type or value from the core-schema reading.
        # A scanner failure counts as a difference, because the other side would not fail the same way.
        def divergent?(scanner, text)
          psych = scanner.tokenize(text)
          core = resolve(text)
          return true unless psych.class.equal?(core.class)
          return false if core.is_a?(Float) && core.nan? && psych.nan?

          psych != core
        rescue StandardError
          true
        end
      end

      # Builds the AST as `Psych.parse_stream` does and stops the parser at the first collection nested beyond
      # `MAX_DEPTH`. The scan in libyaml costs the square of the flow nesting, so a block within the size limit
      # could otherwise take seconds before `check_nodes!` ever saw its depth.
      class BoundedTreeBuilder < Psych::TreeBuilder
        def initialize
          super
          @depth = 0
        end

        def start_sequence(*)
          descend
          super
        end

        def start_mapping(*)
          descend
          super
        end

        def end_sequence
          @depth -= 1
          super
        end

        def end_mapping
          @depth -= 1
          super
        end

        private

        def descend
          @depth += 1
          raise Error.new(:parse) if @depth > MAX_DEPTH
        end
      end
      private_constant :BoundedTreeBuilder

      # Extracts and parses the frontmatter of a `SKILL.md` given as bytes; returns a Hash with String keys.
      def load(bytes)
        parse(extract(bytes))
      end

      # The text between the opening `---` line and the next `---` line. A leading UTF-8 BOM is skipped
      # here only; digests always cover the raw bytes. Lines end with `\n` or `\r\n`.
      def extract(bytes)
        data = bytes.b
        data = data.byteslice(BOM.bytesize..-1) if data.start_with?(BOM)
        text = data.force_encoding(Encoding::UTF_8)
        raise Error.new(:parse) unless text.valid_encoding?

        lines = text.each_line
        first = begin
          lines.next
        rescue StopIteration
          raise Error.new(:parse)
        end
        raise Error.new(:parse) unless delimiter_line?(first) && first.end_with?("\n") && !foreign_break?(first)

        block = +""
        closed = false
        # `loop` ends when `next` raises StopIteration at the end of the text; `each` would restart from
        # the first line instead of continuing after it.
        loop do
          line = lines.next
          raise Error.new(:parse) if foreign_break?(line)

          if delimiter_line?(line)
            closed = true
            break
          end

          block << line
          raise Error.new(:parse) if block.bytesize > MAX_BLOCK_BYTES
        end
        raise Error.new(:parse) unless closed

        block
      end

      # Parses an extracted block under the rules above.
      def parse(block)
        document = single_document(block)
        check_nodes!(document.root)

        value = begin
          Psych.safe_load(block, permitted_classes: [], permitted_symbols: [], aliases: false)
        rescue Psych::Exception
          raise Error.new(:parse)
        end
        raise Error.new(:parse) unless value.is_a?(Hash)

        begin
          Json.normalize(value)
        rescue ArgumentError
          raise Error.new(:parse)
        end
      end

      # Whether two normalized frontmatter Hashes are equal, with Integer and Float kept distinct.
      def equal?(expected, actual)
        Json.equal?(expected, actual)
      end

      private

      def delimiter_line?(line)
        line.chomp == DELIMITER
      end

      # A line break the delimiter scan above does not see but Psych does: a carriage return that is not part of
      # a `\r\n` ending, or one of the YAML 1.1-only separators. The scan and Psych must never disagree, and neither
      # must Psych and a YAML 1.2 reader. Only an exact `\r\n` suffix is taken off before looking (`chomp` would
      # also strip a lone `\r` or the `\r` of `\r\r\n`).
      def foreign_break?(line)
        line.delete_suffix("\r\n").include?("\r") || line.match?(UNICODE_BREAKS)
      end

      # `Psych.parse` and `safe_load` read only the first document, so a `...` or a second `---` inside
      # the block would hide content from every check; the stream must hold exactly one implicit document.
      def single_document(block)
        stream = begin
          parser = Psych::Parser.new(BoundedTreeBuilder.new)
          parser.parse(block)
          parser.handler.root
        rescue Psych::Exception
          raise Error.new(:parse)
        end
        documents = stream.children
        raise Error.new(:parse) unless documents.size == 1

        document = documents.first
        version = document.version
        unless (version.nil? || version.empty?) && document.tag_directives.empty? &&
            document.implicit && document.implicit_end && document.root.is_a?(Psych::Nodes::Mapping)
          raise Error.new(:parse)
        end

        document
      end

      # Walks the AST iteratively, before `safe_load` ever builds Ruby objects from it.
      def check_nodes!(root)
        scanner = Psych::ScalarScanner.new(Psych::ClassLoader.new)
        stack = [[root, 1]]
        until stack.empty?
          node, depth = stack.pop
          raise Error.new(:parse) if depth > MAX_DEPTH
          raise Error.new(:parse) if node.respond_to?(:tag) && node.tag

          case node
          when Psych::Nodes::Scalar
            raise Error.new(:parse) if node.plain && CoreSchema.divergent?(scanner, node.value)
          when Psych::Nodes::Sequence
            node.children.each { |child| stack.push([child, depth + 1]) }
          when Psych::Nodes::Mapping
            check_mapping!(node, depth, stack, scanner)
          else
            raise Error.new(:parse)
          end
        end
      end

      def check_mapping!(node, depth, stack, scanner)
        keys = {}
        node.children.each_slice(2) do |key, value|
          raise Error.new(:parse) unless key.is_a?(Psych::Nodes::Scalar) && key.tag.nil?

          text = key.value
          if key.plain
            raise Error.new(:parse) if CoreSchema.divergent?(scanner, text)
            raise Error.new(:parse) unless CoreSchema.resolve(text).is_a?(String)
          end
          raise Error.new(:parse) if text == MERGE_KEY || keys.key?(text)

          keys[text] = true
          stack.push([value, depth + 1])
        end
      end
    end
  end
end
