# frozen_string_literal: true

module MCP
  module StringUtils
    extend self

    def handle_from_class_name(class_name)
      underscore(demodulize(class_name))
    end

    private

    def demodulize(path)
      path.to_s.split("::").last || path.to_s
    end

    def underscore(camel_cased_word)
      camel_cased_word.dup
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("-", "_")
        .downcase
    end
  end
end
