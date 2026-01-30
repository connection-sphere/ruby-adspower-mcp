# frozen_string_literal: true

require "time"
require "logger"
require "selenium-webdriver"
require "adspower-client"

module RubyAdsPowerMCP
  class BrowserManager
    DEFAULT_HEADLESS = false
    DEFAULT_READ_TIMEOUT = 180

    Session = Struct.new(:driver, :headless, :started_at, keyword_init: true)

    def initialize(env: ENV, logger: Logger.new($stderr))
      @env = env
      @logger = logger
      @sessions = {}
      @client = build_client
      at_exit { shutdown }
    end

    def start_session(profile_id, headless: default_headless?, read_timeout: DEFAULT_READ_TIMEOUT)
      profile = normalize_profile_id(profile_id)
      existing = sessions[profile]
      if existing && session_alive?(existing.driver)
        existing.headless = headless unless headless.nil?
        return session_info(profile, existing, reused: true)
      end

      stop_session(profile, reason: "stale session") if existing

      driver = client.driver2(profile, headless: headless, read_timeout: read_timeout || DEFAULT_READ_TIMEOUT)
      entry = Session.new(driver: driver, headless: headless, started_at: Time.now.utc)
      sessions[profile] = entry
      session_info(profile, entry)
    rescue => e
      sessions.delete(profile)
      raise e
    end

    def stop_session(profile_id, reason: nil)
      profile = normalize_profile_id(profile_id)
      entry = sessions.delete(profile)
      return { profile_id: profile, stopped: false, reason: "not_running" } unless entry

      safe_quit(entry.driver)
      client.stop(profile)

      {
        profile_id: profile,
        stopped: true,
        reason: reason || "user_request"
      }
    rescue => e
      {
        profile_id: profile,
        stopped: false,
        reason: e.message
      }
    end

    def navigate(profile_id, url, headless: default_headless?)
      driver = driver_for(profile_id, headless: headless)
      driver.get(url)
      {
        profile_id: profile_id,
        current_url: driver.current_url,
        title: driver.title
      }
    end

    def dom_snapshot(profile_id, locator: nil, max_nodes: 20, headless: default_headless?)
      driver = driver_for(profile_id, headless: headless)
      if locator.nil?
        return {
          profile_id: profile_id,
          mode: "document",
          node_count: nil,
          html: driver.page_source
        }
      end

      elements = resolve_elements(driver, locator)
      limited = elements.first([max_nodes, 1].max)
      serialized = limited.map do |element|
        {
          tag_name: element.tag_name,
          text: element.text,
          outer_html: element.attribute("outerHTML"),
          attributes: serialized_attributes(element)
        }
      end

      {
        profile_id: profile_id,
        mode: "elements",
        selector: locator,
        node_count: elements.size,
        nodes: serialized,
        truncated: elements.size > limited.size
      }
    end

    def execute_script(profile_id, script, args: [], headless: default_headless?)
      raise ArgumentError, "script cannot be empty" if script.to_s.strip.empty?

      driver = driver_for(profile_id, headless: headless)
      value = driver.execute_script(script, *Array(args))

      {
        profile_id: profile_id,
        result: sanitize(value)
      }
    end

    def run_workflow(profile_id, code, headless: default_headless?)
      driver = driver_for(profile_id, headless: headless)
      WorkflowSandbox.run(driver, code)
    end

    def shutdown
      sessions.each do |profile_id, entry|
        safe_quit(entry.driver)
        begin
          client.stop(profile_id)
        rescue => e
          logger.warn("stop failed for #{profile_id}: #{e.message}")
        end
      end
      sessions.clear
    end

    private

    attr_reader :env, :logger, :sessions, :client

    def driver_for(profile_id, headless: default_headless?)
      session = sessions[normalize_profile_id(profile_id)]
      return session.driver if session && session_alive?(session.driver)

      start_session(profile_id, headless: headless)
      sessions[normalize_profile_id(profile_id)].driver
    end

    def resolve_elements(driver, locator)
      using = (locator["using"] || locator[:using] || "css").to_s.downcase
      value = locator["value"] || locator[:value]
      raise ArgumentError, "locator value cannot be empty" if value.to_s.strip.empty?

      strategy = case using
                 when "css", "css_selector" then :css
                 when "xpath" then :xpath
                 when "id" then :id
                 when "name" then :name
                 when "class", "class_name" then :class_name
                 else
                   raise ArgumentError, "Unsupported locator strategy #{using}"
                 end

      driver.find_elements(strategy, value)
    end

    def session_alive?(driver)
      driver && driver.window_handles
      true
    rescue Selenium::WebDriver::Error::WebDriverError, Errno::ECONNREFUSED
      false
    end

    def safe_quit(driver)
      driver&.quit
    rescue Selenium::WebDriver::Error::WebDriverError
      # best effort
    end

    def serialized_attributes(element)
      element.attribute("outerHTML")
      script = <<~JS
        const attrs = arguments[0].attributes;
        const output = {};
        for (let i = 0; i < attrs.length; i += 1) {
          output[attrs[i].name] = attrs[i].value;
        }
        return output;
      JS
      element.driver.execute_script(script, element)
    rescue
      {}
    end

    def sanitize(value)
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass
        value
      when Array
        value.map { |v| sanitize(v) }
      when Hash
        value.transform_values { |v| sanitize(v) }
      else
        value.inspect
      end
    end

    def session_info(profile_id, session, reused: false)
      {
        profile_id: profile_id,
        headless: session.headless,
        started_at: session.started_at.iso8601,
        reused: reused
      }
    end

    def normalize_profile_id(value)
      str = value.to_s.strip
      raise ArgumentError, "profile_id is required" if str.empty?
      str
    end

    def default_headless?
      raw = env.fetch("ADSPOWER_HEADLESS", nil)
      return DEFAULT_HEADLESS if raw.nil?
      %w[1 true yes].include?(raw.to_s.strip.downcase)
    end

    def build_client
      api_key = env.fetch("ADSPOWER_API_KEY") do
        raise ArgumentError, "Set ADSPOWER_API_KEY to use ruby-adspower-mcp"
      end

      listener = env.fetch("ADSPOWER_HOST", "http://127.0.0.1")
      port = env.fetch("ADSPOWER_PORT", "50325")
      server_log = env.fetch("ADSPOWER_SERVER_LOG", "~/adspower-client.log")

      AdsPowerClient.new(
        key: api_key,
        port: port,
        adspower_listener: listener,
        server_log: server_log
      )
    end
  end
end
