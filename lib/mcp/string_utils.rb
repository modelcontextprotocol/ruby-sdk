# frozen_string_literal: true

module MCP
  module StringUtils
    extend self

    NAMESPACE_SEPARATOR = "/"

    def handle_from_class_name(class_name)
      class_name.to_s.split("::").map do |name|
        underscore(name)
      end.join(NAMESPACE_SEPARATOR)
    end

    private

    def underscore(camel_cased_word)
      camel_cased_word.dup
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("-", "_")
        .downcase
    end
  end
end
