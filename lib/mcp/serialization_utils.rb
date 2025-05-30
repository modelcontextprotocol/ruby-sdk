# frozen_string_literal: true

module MCP
  module SerializationUtils
    def to_h(obj)
      obj.instance_variables.each_with_object({}) do |var, hash|
        key = var.to_s.delete("@").to_sym
        value = @oauth_metadata.instance_variable_get(var)
        hash[key] = value unless value.nil?
      end
    end
  end
end
