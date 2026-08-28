# frozen_string_literal: true

# Liquid 4.0.3 (pinned by github-pages) still calls the taint API that Ruby 3.2 removed.
# Restore it as a no-op for the local docs preview only; `rake docs:preview` loads
# this file via `RUBYOPT`, so nothing outside the preview process is affected.
class Object
  def tainted?
    false
  end

  def taint
    self
  end

  def untaint
    self
  end
end
