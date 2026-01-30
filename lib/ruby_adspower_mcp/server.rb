# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "browser_manager"
require_relative "workflow_sandbox"

module RubyAdsPowerMCP
  class Server
    MAX_DOM_NODES = 50

    def initialize(input: $stdin, output: $stdout, env: ENV)
      @input = input
      @output = output
      @browser_manager = BrowserManager.new(env: env)
    end

    def run
      input.each_line do |line|
        next if line.strip.empty?
        dispatch(JSON.parse(line))
      rescue JSON::ParserError => e
        send_error(nil, "Invalid JSON: #{e.message}")
      end
    rescue Interrupt
      # graceful exit
    ensure
      browser_manager.shutdown
    end

    private

    attr_reader :input, :output, :browser_manager

    def dispatch(message)
      id = message["id"]
      method = message["method"]

      case method
      when "initialize"
        send_response(id, initialize_payload)
      when "tools/list"
        send_response(id, { tools: tools_definition })
      when "tools/call"
        handle_tool_call(id, message.fetch("params", {}))
      else
        send_error(id, "Unknown method #{method}")
      end
    rescue StandardError => e
      send_error(id, e.message)
    end

    def initialize_payload
      {
        serverInfo: {
          name: "ruby-adspower-mcp",
          version: RubyAdsPowerMCP::VERSION
        },
        tools: tools_definition
      }
    end

    def handle_tool_call(id, params)
      tool_name = params.fetch("name")
      arguments = params.fetch("arguments", {}) || {}

      result = case tool_name
               when "adspower.start_session"
                 browser_manager.start_session(
                   arguments.fetch("profile_id"),
                   headless: arguments.fetch("headless", nil),
                   read_timeout: arguments.fetch("read_timeout", BrowserManager::DEFAULT_READ_TIMEOUT)
                 )
               when "adspower.stop_session"
                 browser_manager.stop_session(arguments.fetch("profile_id"))
               when "adspower.navigate"
                 browser_manager.navigate(
                   arguments.fetch("profile_id"),
                   arguments.fetch("url"),
                   headless: arguments.fetch("headless", nil)
                 )
               when "adspower.dom_snapshot"
                 max_nodes = clamp_max_nodes(arguments["max_nodes"])
                 browser_manager.dom_snapshot(
                   arguments.fetch("profile_id"),
                   locator: arguments["locator"],
                   max_nodes: max_nodes,
                   headless: arguments.fetch("headless", nil)
                 )
               when "adspower.execute_script"
                 browser_manager.execute_script(
                   arguments.fetch("profile_id"),
                   arguments.fetch("script"),
                   args: arguments["args"],
                   headless: arguments.fetch("headless", nil)
                 )
               when "adspower.run_workflow"
                 browser_manager.run_workflow(
                   arguments.fetch("profile_id"),
                   arguments.fetch("code"),
                   headless: arguments.fetch("headless", nil)
                 )
               else
                 raise ArgumentError, "Unknown tool #{tool_name}"
               end

      send_response(id, result)
    end

    def clamp_max_nodes(value)
      n = Integer(value || MAX_DOM_NODES)
      return 1 if n < 1
      return MAX_DOM_NODES if n > MAX_DOM_NODES
      n
    rescue ArgumentError, TypeError
      MAX_DOM_NODES
    end

    def tools_definition
      @tools_definition ||= [
        {
          name: "adspower.start_session",
          description: "Attach to an AdsPower profile and return session metadata.",
          input_schema: {
            type: "object",
            required: %w[profile_id],
            properties: {
              profile_id: { type: "string" },
              headless: {
                type: "boolean",
                description: "Override the default headless mode for this session."
              },
              read_timeout: {
                type: "integer",
                description: "Selenium read timeout in seconds.",
                minimum: 30
              }
            }
          }
        },
        {
          name: "adspower.stop_session",
          description: "Stop an AdsPower profile and close Selenium.",
          input_schema: {
            type: "object",
            required: %w[profile_id],
            properties: {
              profile_id: { type: "string" }
            }
          }
        },
        {
          name: "adspower.navigate",
          description: "Navigate the profile's browser to a URL.",
          input_schema: {
            type: "object",
            required: %w[profile_id url],
            properties: {
              profile_id: { type: "string" },
              url: { type: "string", format: "uri" },
              headless: { type: "boolean" }
            }
          }
        },
        {
          name: "adspower.dom_snapshot",
          description: "Capture the full DOM or specific nodes using a locator.",
          input_schema: {
            type: "object",
            required: ["profile_id"],
            properties: {
              profile_id: { type: "string" },
              locator: {
                type: "object",
                properties: {
                  using: { type: "string", enum: %w[css css_selector xpath id name class class_name] },
                  value: { type: "string" }
                }
              },
              max_nodes: {
                type: "integer",
                minimum: 1,
                maximum: MAX_DOM_NODES,
                description: "Maximum nodes to return when using a locator."
              },
              headless: { type: "boolean" }
            }
          }
        },
        {
          name: "adspower.execute_script",
          description: "Execute JavaScript in the active AdsPower browser context.",
          input_schema: {
            type: "object",
            required: %w[profile_id script],
            properties: {
              profile_id: { type: "string" },
              script: { type: "string" },
              args: {
                type: "array",
                items: { type: ["string", "number", "boolean", "null"] }
              },
              headless: { type: "boolean" }
            }
          }
        },
        {
          name: "adspower.run_workflow",
          description: "Execute Ruby automation code that receives the Selenium driver.",
          input_schema: {
            type: "object",
            required: %w[profile_id code],
            properties: {
              profile_id: { type: "string" },
              code: {
                type: "string",
                description: "Ruby source. The `driver` variable is pre-bound to the Selenium instance."
              },
              headless: { type: "boolean" }
            }
          }
        }
      ]
    end

    def send_response(id, result)
      output.puts(JSON.generate(jsonrpc: "2.0", id: id, result: result))
      output.flush
    end

    def send_error(id, message)
      output.puts(JSON.generate(jsonrpc: "2.0", id: id, error: { message: message }))
      output.flush
    end
  end
end
