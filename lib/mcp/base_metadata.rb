# frozen_string_literal: true

module MCP
  # Provides shared functionality for classes implementing the BaseMetadata interface from the MCP spec.
  #
  # BaseMetadata defines:
  # - name: Intended for programmatic or logical use
  # - title: Intended for UI and end-user contexts (optional)
  #
  # This module provides display_name logic that follows the spec:
  # - Generally: use title if present, otherwise fall back to name
  # - For Tool: use annotations.title first, then title, then name
  module BaseMetadata
    # Returns the appropriate display name according to spec priority.
    #
    # For most classes: title (if present) or name
    # For Tool: annotations.title, title, or name
    #
    # @return [String] the display name
    def display_name
      if respond_to?(:annotations_value) && annotations_value&.title
        annotations_value.title
      elsif respond_to?(:title_value)
        title_value || name_value
      elsif respond_to?(:title)
        title || name
      else
        name
      end
    end

    # Module containing class-level methods for BaseMetadata.
    # Use by including BaseMetadata and extending BaseMetadata::ClassMethods.
    module ClassMethods
      # Returns the appropriate display name according to spec priority.
      #
      # For Tool: annotations.title, title, or name
      # For others: title or name
      #
      # @return [String] the display name
      def display_name
        if respond_to?(:annotations_value) && annotations_value&.title
          annotations_value.title
        elsif title_value
          title_value
        else
          name_value
        end
      end

      # Accessor for name value, must be implemented by including class
      def name_value
        raise NotImplementedError, "#{self} must implement name_value"
      end

      # Accessor for title value
      def title_value
        @title_value
      end

      # Class method to set or get title
      # Note: Classes using this module should define their own NOT_SET constant
      # which is used as a sentinel value to distinguish between getter and setter calls
      #
      # @param value [Object] the title value or NOT_SET to read
      # @return [String, nil] the title value when reading
      def title(value = NOT_SET)
        if value == NOT_SET
          @title_value
        else
          @title_value = value
        end
      end
    end
  end
end
