# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    class PaginationTest < ActiveSupport::TestCase
      class PaginationHost
        include Pagination

        # Expose private methods for testing.
        public :paginate, :cursor_from

        # RequestHandlerError must be accessible.
        RequestHandlerError = Server::RequestHandlerError
      end

      setup do
        @host = PaginationHost.new
        @items = [{ name: "a" }, { name: "b" }, { name: "c" }, { name: "d" }, { name: "e" }]
        @request = { method: "tools/list" }
      end

      test "paginate returns all items when page_size is nil and no cursor" do
        result = @host.paginate(@items, cursor: nil, page_size: nil, request: @request)

        assert_equal @items, result[:items]
        assert_nil result[:next_cursor]
      end

      test "paginate returns first page with nextCursor when page_size is set" do
        result = @host.paginate(@items, cursor: nil, page_size: 2, request: @request)

        assert_equal [{ name: "a" }, { name: "b" }], result[:items]
        assert_not_nil result[:next_cursor]
      end

      test "paginate returns correct second page when cursor is provided" do
        first = @host.paginate(@items, cursor: nil, page_size: 2, request: @request)
        second = @host.paginate(@items, cursor: first[:next_cursor], page_size: 2, request: @request)

        assert_equal [{ name: "c" }, { name: "d" }], second[:items]
        assert_not_nil second[:next_cursor]
      end

      test "paginate returns last page without nextCursor" do
        first = @host.paginate(@items, cursor: nil, page_size: 2, request: @request)
        second = @host.paginate(@items, cursor: first[:next_cursor], page_size: 2, request: @request)
        third = @host.paginate(@items, cursor: second[:next_cursor], page_size: 2, request: @request)

        assert_equal [{ name: "e" }], third[:items]
        assert_nil third[:next_cursor]
      end

      test "paginate with page_size equal to items count returns all without nextCursor" do
        result = @host.paginate(@items, cursor: nil, page_size: 5, request: @request)

        assert_equal @items, result[:items]
        assert_nil result[:next_cursor]
      end

      test "paginate with page_size larger than items count returns all without nextCursor" do
        result = @host.paginate(@items, cursor: nil, page_size: 100, request: @request)

        assert_equal @items, result[:items]
        assert_nil result[:next_cursor]
      end

      test "paginate with empty items returns empty array" do
        result = @host.paginate([], cursor: nil, page_size: 2, request: @request)

        assert_equal [], result[:items]
        assert_nil result[:next_cursor]
      end

      test "paginate raises RequestHandlerError for non-numeric cursor" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: "not_a_number", page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate raises RequestHandlerError for Integer cursor (spec requires string)" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: 2, page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate raises RequestHandlerError for Float cursor (spec requires string)" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: 1.5, page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate raises RequestHandlerError for negative offset cursor" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: "-1", page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate raises RequestHandlerError for out-of-range cursor" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: "100", page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate returns all items from cursor offset when page_size is nil" do
        result = @host.paginate(@items, cursor: "2", page_size: nil, request: @request)

        assert_equal [{ name: "c" }, { name: "d" }, { name: "e" }], result[:items]
        assert_nil result[:next_cursor]
      end

      test "paginate raises RequestHandlerError when cursor points exactly at items.size" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate(@items, cursor: @items.size.to_s, page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate on empty items with any cursor raises RequestHandlerError" do
        error = assert_raises(RequestHandlerError) do
          @host.paginate([], cursor: "0", page_size: 2, request: @request)
        end
        assert_equal :invalid_params, error.error_type
      end

      test "cursor_from returns nil for nil request" do
        assert_nil @host.cursor_from(nil)
      end

      test "cursor_from returns cursor for Hash request" do
        assert_equal "abc", @host.cursor_from(cursor: "abc")
      end

      test "cursor_from returns nil when Hash request has no cursor" do
        assert_nil @host.cursor_from({})
      end

      test "cursor_from raises RequestHandlerError for non-Hash request" do
        error = assert_raises(RequestHandlerError) do
          @host.cursor_from([1, 2, 3])
        end
        assert_equal :invalid_params, error.error_type
      end

      test "paginate with page_size 1 iterates one item at a time" do
        results = []
        cursor = nil

        loop do
          page = @host.paginate(@items, cursor: cursor, page_size: 1, request: @request)
          results.concat(page[:items])
          cursor = page[:next_cursor]
          break unless cursor
        end

        assert_equal @items, results
      end
    end
  end
end
