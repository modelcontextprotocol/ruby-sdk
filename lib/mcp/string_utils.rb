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
      camel_cased_word
        .gsub(/(?<=[A-Z])(?=[A-Z][a-z])/, "_")
        .gsub(/(?<=[a-z\d])(?=[A-Z])/, "_")
        .tr("-", "_")
        .downcase
    end
  end
end
