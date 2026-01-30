# frozen_string_literal: true

require "stringio"

module RubyAdsPowerMCP
  # Executes user-provided Ruby against the live Selenium driver.
  # Stdout is captured so Copilot can inspect script output.
  class WorkflowSandbox
    class << self
      def run(driver, code)
        raise ArgumentError, "driver is required" unless driver
        raise ArgumentError, "code cannot be empty" if code.to_s.strip.empty?

        output = StringIO.new
        sanitized = nil
        binding_context = binding
        binding_context.local_variable_set(:driver, driver)

        redirect_stdout(output) do
          value = binding_context.eval(code, __FILE__, __LINE__)
          sanitized = sanitize(value)
        end

        {
          status: "ok",
          result: sanitized,
          stdout: output.string
        }
      rescue Exception => e
        {
          status: "error",
          error_class: e.class.name,
          error_message: e.message,
          backtrace: (e.backtrace || []).first(10),
          stdout: output&.string.to_s
        }
      ensure
        output&.close unless output&.closed?
      end

      private

      def redirect_stdout(io)
        original = $stdout
        $stdout = io
        yield
      ensure
        $stdout = original
      end

      def sanitize(value)
        case value
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          value.inspect
        end
      end
    end
  end
end
