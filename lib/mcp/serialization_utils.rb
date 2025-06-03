# frozen_string_literal: true

module MCP
  module SerializationUtils
    def to_h(obj)
      obj.instance_variables.each_with_object({}) do |var, hash|
        key = var.to_s.delete("@").to_sym
        value = obj.instance_variable_get(var)
        hash[key] = value unless value.nil?
      end
    end

    def stringify_keys(h)
      h.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
    end
  end
end
