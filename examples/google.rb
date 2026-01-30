#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "optparse"
require "json"
require "uri"

project_root = File.expand_path("..", __dir__)
env_file = File.join(project_root, ".env")
require "dotenv/load" if File.exist?(env_file)

require_relative "../lib/ruby_adspower_mcp"

options = {
	profile_id: ENV["ADSPOWER_PROFILE_ID"],
	headless: nil,
	max_results: Integer(ENV.fetch("GOOGLE_MAX_RESULTS", "10"))
}

OptionParser.new do |opts|
	opts.banner = "Usage: examples/google.rb [options] SEARCH_QUERY"

	opts.on("-p", "--profile ID", "AdsPower profile ID (defaults to ADSPOWER_PROFILE_ID)") do |value|
		options[:profile_id] = value
	end

	opts.on("--headless", "Force headless mode") { options[:headless] = true }
	opts.on("--headed", "Force headed mode") { options[:headless] = false }

	opts.on("-m", "--max-results N", Integer, "Maximum organic results to return (default 10)") do |value|
		options[:max_results] = [[value, 1].max, 20].min
	end

	opts.on("-h", "--help", "Show this message") do
		puts opts
		exit
	end
end.parse!

query = ARGV.join(" ").strip
abort "Please provide a Google search query." if query.empty?

profile_id = options[:profile_id] || abort("Set ADSPOWER_PROFILE_ID or use --profile to choose a profile.")
max_results = [[options[:max_results], 1].max, 20].min

manager = RubyAdsPowerMCP::BrowserManager.new(env: ENV)

begin
	session = manager.start_session(profile_id, headless: options[:headless])
	puts "Using profile #{session[:profile_id]} (headless=#{session[:headless]}, reused=#{session[:reused]})"

	params = URI.encode_www_form(q: query, udm: "14")
	manager.navigate(profile_id, "https://www.google.com/search?#{params}")

	# Ensure Google has rendered the organic results before scraping them with JavaScript.
	workflow_code = <<~RUBY
		query = #{query.inspect}
		wait = Selenium::WebDriver::Wait.new(timeout: 30)

		wait.until do
			driver.execute_script('return document.readyState') == 'complete'
		rescue Selenium::WebDriver::Error::JavascriptError
			false
		end

		consent_frame = driver.find_elements(:css, 'iframe[src*="consent.google.com"], iframe[name^="callout"]').first
		if consent_frame
			driver.switch_to.frame(consent_frame)
		end

		consent_button = driver.find_elements(:css, '#L2AGLb').first
		if consent_button.nil?
			consent_button = driver.find_elements(:css, 'button[aria-label="Accept all"]').first
		end
		if consent_button.nil?
			consent_button = driver.find_elements(:xpath, "//button[contains(., 'I agree')] | //button[contains(., 'Accept all')]").first
		end

		if consent_button
			consent_button.click
			driver.switch_to.default_content
		end

		search_box = driver.find_elements(:css, 'textarea[name="q"], input[name="q"]').first
		raise "Google search box not found" unless search_box

		current_value = search_box.attribute('value').to_s.strip
		unless current_value.casecmp?(query)
			search_box.clear
			search_box.send_keys(query, :enter)
		else
			search_box.send_keys(:enter)
		end

		wait.until do
			driver.find_elements(:css, '#search div.g h3, #search div.MjjYud h3').any?
		end
	RUBY

	workflow = manager.run_workflow(profile_id, workflow_code)
	if workflow[:status] == "error"
		warn "Workflow failed: #{workflow[:error_class]} - #{workflow[:error_message]}"
		stdout = workflow[:stdout].to_s.strip
		warn stdout unless stdout.empty?
		raise workflow[:error_message]
	end

	script = <<~JS
		const max = arguments[0] || 10;
		const organicBlocks = document.querySelectorAll('#search div.g, #search div.MjjYud');
		const results = [];
		const seen = new Set();

		for (const block of organicBlocks) {
			if (block.closest('#tads, #bottomads, #taw, .commercial-unit-desktop-top, .ellip-table')) {
				continue;
			}

			const titleEl = block.querySelector('h3');
			const linkEl = block.querySelector('a[href]');
			if (!titleEl || !linkEl) {
				continue;
			}

			const url = linkEl.href;
			if (!url || seen.has(url)) {
				continue;
			}
			seen.add(url);

			const snippetEl = block.querySelector('.VwiC3b, .MUxGbd, .BNeawe, .kno-rdesc span');
			results.push({
				title: titleEl.textContent.trim(),
				url: url,
				snippet: snippetEl ? snippetEl.textContent.trim() : ""
			});

			if (results.length >= max) {
				break;
			}
		}

		return results;
	JS

	response = manager.execute_script(profile_id, script, args: [max_results])
	organic_results = response.fetch(:result, [])

	puts JSON.pretty_generate(organic_results)
rescue Interrupt
	warn "Interrupted"
	exit 130
rescue StandardError => e
	warn "Search failed: #{e.class}: #{e.message}"
	exit 1
ensure
	manager.stop_session(profile_id)
end