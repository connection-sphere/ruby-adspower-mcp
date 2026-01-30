# ruby-adspower-mcp

Model Context Protocol (MCP) server that lets GitHub Copilot Chat spin up real AdsPower browser profiles, validate frontend builds, and iterate on Selenium-based RPA bots until they pass live testing.

## Prompt Example

```text
1. Use adspower.start_session with {"profile_id":"koyynup","headless":false}
2. In the browser that you just opened, go to the page `https://google.com`
3. Write into the file `google.rb` a script that executes a google seearch, and return an array of organic results, ignoring ads.
4. Use the MCP `ruby-adspower-mcp` to test your own code and verify it is working fine.
```

## Why this exists
- **Frontend loops:** Render ERB/HTML/CSS/JS in a real AdsPower-controlled Chrome instance, inspect DOM/JS state, and re-run after each fix.
- **Automation loops:** Execute Ruby automation snippets that receive the actual `Selenium::WebDriver` instance, observe failures, and patch the script without leaving Copilot.
- **Safety & cleanup:** Reuses [adspower-client](https://github.com/MassProspecting/adspower-client) primitives for profile lifecycle, so every browser session is started/stopped exactly as AdsPower expects.

## Requirements
- Ruby 3.1.2
- AdsPower desktop app (or headless server) running on the same host
- Valid AdsPower API key with Local API enabled
- ChromeDriver matching the AdsPower Chromium build (handled by your AdsPower install)

## Installation
```bash
git clone https://github.com/your-org/ruby-adspower-mcp.git
cd ruby-adspower-mcp
bundle install
chmod +x bin/ruby-adspower-mcp
```

## Configuration
The server reads the following environment variables (load them via `.env` or export in your shell). At minimum you must set `ADSPOWER_API_KEY`.

| Variable | Required | Purpose |
| --- | --- | --- |
| `ADSPOWER_API_KEY` | ✅ | AdsPower Local API key. |
| `ADSPOWER_HOST` |  | Local API host (default `http://127.0.0.1`). |
| `ADSPOWER_PORT` |  | Local API port (default `50325`). |
| `ADSPOWER_HEADLESS` |  | Default headless mode (`true` / `false`, default `false`). |
| `ADSPOWER_SERVER_LOG` |  | Where AdsPower server logs should go (default `~/adspower-client.log`). |

Example `.env`:

```bash
ADSPOWER_API_KEY=xxxxxxxxxxxxxxxx
ADSPOWER_HOST=http://127.0.0.1
ADSPOWER_PORT=50325
ADSPOWER_HEADLESS=false
```

## Registering with Copilot (workspace scoped)
Add `.vscode/mcp.json` to your project that uses this browser automation:

```json
{
	"servers": {
		"adspower": {
			"command": "/absolute/path/to/ruby-adspower-mcp/bin/ruby-adspower-mcp",
			"args": []
		}
	}
}
```

Reload VS Code (Command Palette → “Developer: Reload Window”) after editing so Copilot picks up the new MCP server.

## Running the server manually
```bash
bundle exec ruby bin/ruby-adspower-mcp
```
The server speaks JSON-RPC over stdio (as required by MCP). Normally Copilot launches it automatically; running it manually is useful for debugging environment issues.

## Example Prompts

```text
In the `ruby-adspower-mcp` project, use adspower.start_session with {"profile_id":"YOUR_PROFILE","headless":false} so we have a live browser to debug the current signup form.
```

```text
In the `ruby-adspower-mcp` project, call adspower.navigate for profile "YOUR_PROFILE" and load http://localhost:3000 to verify that yesterday's CSS fixes render correctly.
```

```text
In the `ruby-adspower-mcp` project, run adspower.dom_snapshot with {"profile_id":"YOUR_PROFILE","locator":{"using":"css","value":"form#signup input"},"max_nodes":10} and summarize which inputs fail validation.
```

```text
In the `ruby-adspower-mcp` project, execute adspower.execute_script using {"profile_id":"YOUR_PROFILE","script":"return window.__LAST_ERROR__ || null;"} to see if the frontend logged runtime errors.
```

```text
In the `ruby-adspower-mcp` project, call adspower.run_workflow with {"profile_id":"YOUR_PROFILE","code":"driver.navigate.to('https://app.example.com/login'); driver.find_element(:css,'#email').send_keys('bot@example.com'); driver.find_element(:css,'#password').send_keys('secret', :enter); sleep 2; driver.title"} and report the workflow output.
```

## Available MCP tools

| Tool | What it does |
| --- | --- |
| `adspower.start_session` | Starts or reuses an AdsPower profile and returns session metadata (headless mode, start time). |
| `adspower.stop_session` | Quits Selenium, stops the AdsPower browser, and frees resources. |
| `adspower.navigate` | Calls `driver.get(url)` so Copilot can load local builds or remote staging URLs. |
| `adspower.dom_snapshot` | Returns full HTML or a limited set of nodes found via CSS/XPath/ID/class selectors. |
| `adspower.execute_script` | Runs arbitrary JavaScript in the tab to check DOM state, fire events, or mutate the UI. |
| `adspower.run_workflow` | Evaluates Ruby automation snippets with the Selenium `driver` object already bound. Ideal for RPA flows (click/type/submit, assert, retry). |

Each tool enforces AdsPower profile IDs per call so multiple browser projects can run in parallel.

## Execution flow (frontend)
1. `adspower.start_session` with your profile ID (headless optional).
2. `adspower.navigate` to load the HTML/JS you are iterating on (use `file://` URLs, a local dev server, or a deployed preview).
3. Call `adspower.dom_snapshot` or `adspower.execute_script` to gather the current DOM state, errors, or layout signals.
4. Apply code fixes in your repo, rerun build/integration steps, and trigger another navigation + snapshot until the UI behaves correctly.

## Execution flow (RPA)
1. Start the profile.
2. Use `adspower.run_workflow` to send a Ruby snippet. Example:

```ruby
driver.navigate.to("https://example.com/login")
driver.find_element(:css, "#email").send_keys("bot@example.com")
driver.find_element(:css, "#password").send_keys("secret", :enter)
sleep 2
driver.find_element(:css, "#status").text
```

3. Inspect the returned hash: when `status == "ok"` you get the Ruby return value plus captured stdout; when `status == "error"` you receive the exception class/message/backtrace for diagnosis.
4. Iterate until the automation completes the workflow, then stop the session.

## Validating every change
- AdsPower plus Selenium are the source of truth. Keep the browser open while Copilot edits HTML/JS or Ruby automation, and re-run the relevant tool after every change.
- The MCP server never mocks DOM responses; snapshots and script results come directly from the running tab.
- When a workflow fails, Copilot should fix the code and call the tool again—repeat until the failure disappears.

## Troubleshooting
- **`ADSPOWER_API_KEY missing`** – export the key or create a `.env` file before starting the MCP server.
- **Browser never opens** – confirm the AdsPower desktop app (or headless server) is running and the Local API port matches `ADSPOWER_PORT`.
- **`profile_id is required`** – every tool needs the target AdsPower profile ID; create one ahead of time via the AdsPower UI or `adspower-client` gem.
- **Hanging sessions** – run `adspower.stop_session` or kill the profile from AdsPower’s UI; the MCP server also cleans up on exit.

## References
- [adspower-client README](https://github.com/MassProspecting/adspower-client/blob/main/README.md)
- [adspower-client source](https://github.com/MassProspecting/adspower-client/blob/main/lib/adspower-client.rb)

These docs explain the driver lifecycle patterns that this MCP server follows.

Happy automating!
