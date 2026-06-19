# frozen_string_literal: true

module MCP
  class Server
    module Pagination
      private

      def cursor_from(request)
        return if request.nil?

        unless request.is_a?(Hash)
          raise RequestHandlerError.new("Invalid params", request, error_type: :invalid_params)
        end

        request[:cursor]
      end

      def paginate(items, cursor:, page_size:, request:, &block)
        start_index = 0

        if cursor
          unless cursor.is_a?(String)
            raise RequestHandlerError.new("Invalid cursor", request, error_type: :invalid_params)
          end

          start_index = Integer(cursor, exception: false)
          if start_index.nil? || start_index < 0 || start_index >= items.size
            raise RequestHandlerError.new("Invalid cursor", request, error_type: :invalid_params)
          end
        end

        end_index = page_size ? start_index + page_size : items.size
        page = items[start_index...end_index]
        page = page.map(&block) if block

        result = { items: page }
        result[:next_cursor] = end_index.to_s if end_index < items.size
        result
      end
    end
  end
end
