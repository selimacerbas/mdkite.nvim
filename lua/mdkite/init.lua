-- lua/mdkite/init.lua
-- A config calls setup() whatever the plugin file did (lazy.nvim's config
-- runs it), so below the floor the module is a stub whose every call
-- answers an empty string, and it returns before the requires below, whose
-- code needs 0.10. The text is the floor module's, so notify_once shows it
-- once with the plugin file's (notify_once arrived in 0.7), and it waits for
-- the loop as the plugin file's does: a lazy load on FileType runs inside
-- 0.9's filetype nvim_cmd, where an ERROR notification raised Vim(append)
-- with a traceback. A config that set loaded_mdkite, or loaded_markdown_preview
-- from before the rename, opted out, and the plugin file says nothing then,
-- so the stub says nothing either.
local floor = require("mdkite.floor")
if not floor.ok then
	if not (vim.g.loaded_mdkite or vim.g.loaded_markdown_preview) then
		vim.schedule(function()
			local notify = vim.notify_once or vim.notify
			notify(floor.message, vim.log.levels.ERROR)
		end)
	end
	local function nothing()
		return ""
	end
	return setmetatable({}, {
		__index = function()
			return nothing
		end,
	})
end

local ts = require("mdkite.ts")
local util = require("mdkite.util")

-- The oldest kitehost.nvim this plugin runs on. Its kitehost module is new
-- in that release, the first under the name, so an older server's modules
-- are not found and start refuses, naming this. tests/helpers.lua and
-- ci.yml name the same tag; start_failure_test reds when they part.
local KITEHOST_FLOOR = "v2.0.0"
-- The capabilities start requires, read from features since the two
-- plugins update apart: the Host check keeps a DNS-rebinding page from the
-- token the loopback index bakes, and the failure notices read a start
-- that raises. The asset route is older than both, so a server with them
-- has it.
local REQUIRED_FEATURES = { "host_check", "start_raises" }
-- Only a missing module means an older server or none: an error the server
-- raises while loading is its own and goes on as raised.
local function server_module(name)
	local found, module = pcall(require, name)
	if found then
		return module
	end
	if not tostring(module):find("module '" .. name .. "' not found", 1, true) then
		error(module, 0)
	end
end
local server, server_util
-- Looked up at load and again by every start that has none yet: a config
-- may put kitehost on the runtimepath after this module loaded (an opt
-- package added after setup()), and the lookup at load alone refused
-- every start of that session.
local function find_server()
	if not server then
		server = server_module("kitehost.server")
		server_util = server and require("kitehost.util")
	end
	return server
end
find_server()

local M = {}

-- The names from before the rename work through the 2.x releases, each
-- saying once a session what replaced it. Without the plugin argument
-- vim.deprecate reads the version as Neovim's and stays silent (measured
-- on 0.12.5); the traceback is left out, a second notification that for a
-- command names only this plugin's own frames.
function M._deprecated(name, alternative)
	vim.deprecate(name, alternative, "3.0.0", "mdkite.nvim", false)
end

M.config = {
	port = 0, -- 0 = auto; effective port depends on instance_mode
	host = "127.0.0.1", -- bind address; "0.0.0.0" for network access (e.g. over SSH)
	open_browser = true,

	-- nil = system default browser. String for app/binary name (e.g. "Firefox",
	-- "google-chrome"). Table for full command with args (URL is appended).
	-- On macOS, string values are passed via `open -a <name>`.
	browser = nil,

	-- "takeover" = shared workspace + fixed port, one browser tab across instances
	-- "multi" = per-instance server + browser tab (port 0 recommended)
	instance_mode = "takeover",

	content_name = "content.md",
	index_name = "index.html",

	-- Path to a CSS file injected after the bundled styles, so user rules win
	-- the cascade without !important. Supports ~ and $VARS. "" = disabled.
	custom_css = "",

	-- nil = per-buffer workspace (recommended); set a path to override
	workspace_dir = nil,

	overwrite_index_on_start = true,

	auto_refresh = true,
	auto_refresh_events = { "InsertLeave", "TextChanged", "TextChangedI", "BufWritePost" },
	debounce_ms = 300,
	notify_on_refresh = false,

	-- "js" = browser-side mermaid.js (default, zero deps)
	-- "rust" = pre-render via mermaid-rs-renderer (mmdr) CLI (~400x faster)
	mermaid_renderer = "js",

	-- Load ELK layout engine for mermaid diagrams (requires internet; adds ~800 KB).
	-- Enables %%{init: {"layout": "elk"}}%% in diagrams.
	mermaid_elk = false,

	scroll_sync = true, -- sync browser scroll to cursor position

	-- "dark" or "light"; determines the initial theme of the preview page
	default_theme = "dark",

	-- Render raw HTML embedded in markdown (GitHub-like). Set false when
	-- previewing untrusted markdown: raw HTML runs inside the preview page.
	allow_raw_html = true,

	-- YAML front matter (--- ... --- at the top of the file):
	-- "panel" = strip it from the preview, show in a collapsible panel above
	-- "hide"  = strip it entirely
	-- "raw"   = leave it in the document (renders as markdown)
	yaml_mode = "panel",

	-- Filetypes previewed whole as markdown beside markdown itself, which
	-- always is, e.g. { "quarto", "rmd" }. A dotted filetype with a markdown
	-- part (rzk.markdown) needs no entry.
	filetypes = {},

	-- Fraction (0–1): vertical position of the final line when scrolled to end.
	-- 0.5 = middle of viewport (default), 1.0 = bottom edge (no extra space)
	bottom_padding = 0.5,

	hooks = {
		-- fun(url: string)|nil: called after preview starts; receives the preview URL
		on_start = nil,
		-- fun()|nil: called after preview stops
		on_stop = nil,
	},
}

-- A string raises in ipairs, a table that is no list reads as no names and
-- a name that is not a string matches no buffer, so the last two would
-- leave a preview off with nothing said; the empty name would match every
-- buffer with no filetype.
local function is_filetype_list(value)
	if type(value) ~= "table" or not vim.islist(value) then
		return false
	end
	for _, name in ipairs(value) do
		if type(name) ~= "string" or name == "" then
			return false
		end
	end
	return true
end

-- Built by setup and read by every refresh, so a refresh never builds it.
-- filetypes adds to markdown and never replaces it.
local function filetype_set(names)
	local set = { markdown = true }
	for _, name in ipairs(names) do
		set[name] = true
	end
	return set
end

function M.setup(opts)
	opts = opts or {}
	-- Judged before anything is applied, so a refused call changes nothing.
	if opts.filetypes ~= nil and not is_filetype_list(opts.filetypes) then
		vim.notify(
			'mdkite: filetypes takes a list of filetype names, such as { "quarto" }; setup changed nothing',
			vim.log.levels.ERROR
		)
		return
	end
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	M.config.bottom_padding = math.max(0, math.min(1, M.config.bottom_padding))
	M._mmdr_available = nil -- reset so next check re-probes
	M._filetype_set = filetype_set(M.config.filetypes)
end

-- Internal state
M._augroup = nil
M._last_text_by_buf = {}
M._server_instance = nil
M._debounce_seq = 0
M._workspace_dir = nil
M._mmdr_available = nil -- nil = unchecked, true/false after probe
M._last_scroll_line = nil
M._is_primary = nil -- true/false/nil (takeover mode)
M._takeover_port = nil -- port of primary server (secondary uses for HTTP events)
M._token = nil -- kitehost auth token (primary owns; secondaries read from lockfile)
M._bound_host = nil -- the address the primary's server bound, as kitehost reports it
M._lock_owned = nil -- true once this instance writes the takeover lock
M._filetype_set = filetype_set(M.config.filetypes) -- the filetypes previewed whole; setup rebuilds it

local function effective_port()
	if M.config.port ~= 0 then
		return M.config.port
	end
	if M.config.instance_mode == "takeover" then
		return 8421
	end
	return 0
end

local function is_loopback(host)
	return host == "127.0.0.1" or host == "localhost"
end

---------------------------------------------------------------------------
-- Workspace
---------------------------------------------------------------------------

local function resolve_workspace(bufnr)
	if M.config.workspace_dir then
		return M.config.workspace_dir
	end
	return util.workspace_for_buffer(bufnr)
end

local function ensure_workspace(bufnr)
	local dir = resolve_workspace(bufnr)
	util.mkdirp(dir)
	return dir
end

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function write_index(dir)
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	local src = util.resolve_asset("assets/index.html")
	if not src then
		error("Could not locate assets/index.html in runtimepath. Make sure the plugin ships it.", 0)
	end
	local content = util.read_text(src)

	-- gsub with function replacement: avoids the "%n is a capture reference"
	-- escape problem if any substituted value contains '%'.
	content = content:gsub("__BOTTOM_PADDING__", function()
		return tostring(M.config.bottom_padding)
	end)
	content = content:gsub("__MERMAID_ELK__", function()
		return M.config.mermaid_elk and "true" or "false"
	end)
	-- Anchor to the attribute: index.html also contains the bare placeholder
	-- as a JS sentinel, and substituting that too breaks auth (issue #31).
	-- Bake the token only on loopback binds: on a network bind the index is
	-- served to any peer that can reach the port, and a baked token would
	-- defeat the auth entirely (the browser gets it via ?t= instead).
	content = content:gsub('data%-live%-token="__LIVE_TOKEN__"', function()
		return 'data-live-token="' .. (is_loopback(M._bound_host) and M._token or "") .. '"'
	end)
	content = content:gsub("__THEME__", function()
		return M.config.default_theme
	end)
	content = content:gsub("__ALLOW_HTML__", function()
		return M.config.allow_raw_html ~= false and "true" or "false"
	end)
	content = content:gsub("__YAML_MODE__", function()
		local m = M.config.yaml_mode
		if m ~= "hide" and m ~= "raw" then
			m = "panel"
		end
		return m
	end)

	-- Inline custom CSS after the bundled styles so user rules win the cascade.
	if M.config.custom_css and M.config.custom_css ~= "" then
		local css_src = vim.fn.expand(M.config.custom_css)
		local ok, css = pcall(util.read_text, css_src)
		if ok and css then
			content = content:gsub("</head>", function()
				return "<style>\n" .. css .. "\n</style>\n</head>"
			end, 1)
		else
			vim.notify("mdkite: custom_css not readable: " .. css_src, vim.log.levels.WARN)
		end
	end

	util.write_text(dst, content)
	return dst
end

local function write_index_if_needed(dir)
	if M.config.overwrite_index_on_start then
		return write_index(dir)
	end
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	if not util.file_exists(dst) then
		return write_index(dir)
	end
	-- Rewrite a persisted index whose baked token no longer matches what this
	-- session serves. Covers a fresh token after restart AND a loopback<->
	-- network switch (which flips whether the token is baked at all): a stale
	-- non-empty token on a network bind would otherwise 401 every request.
	local want = 'data-live-token="' .. (is_loopback(M._bound_host) and (M._token or "") or "") .. '"'
	local ok, existing = pcall(util.read_text, dst)
	if not ok or not existing:find(want, 1, true) then
		return write_index(dir)
	end
	return dst
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

local function extract_mermaid_under_cursor_strict(bufnr)
	local ok, text = pcall(ts.extract_under_cursor, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function extract_mermaid_under_cursor(bufnr)
	local text = extract_mermaid_under_cursor_strict(bufnr)
	if text and #text > 0 then
		return text
	end
	local fallback = ts.fallback_scan(bufnr)
	if not fallback or #fallback == 0 then
		error("No ```mermaid fenced code block found under (or above) the cursor")
	end
	return fallback
end

---------------------------------------------------------------------------
-- mermaid-rs-renderer (mmdr) integration
---------------------------------------------------------------------------

---Check if mmdr CLI is available; caches result after first probe.
---@return boolean
local function is_mmdr_available()
	if M._mmdr_available ~= nil then
		return M._mmdr_available
	end
	M._mmdr_available = vim.fn.executable("mmdr") == 1
	if not M._mmdr_available then
		vim.notify(
			"mdkite: mermaid_renderer='rust' but `mmdr` not found in PATH.\n"
				.. "Install: cargo install mermaid-rs-renderer\n"
				.. "Falling back to browser-side mermaid.js.",
			vim.log.levels.WARN
		)
	end
	return M._mmdr_available
end

---Render a single mermaid diagram source via mmdr CLI.
---@param source string Raw mermaid diagram text
---@return string|nil svg SVG string on success
---@return string|nil err Error message on failure
local function render_mermaid_via_mmdr(source)
	local result = vim.fn.system({ "mmdr", "-e", "svg" }, source)
	if vim.v.shell_error ~= 0 then
		return nil, result
	end
	return result, nil
end

-- Expand button SVG used in pre-rendered blocks (matches browser-side fence renderer)
local EXPAND_BTN_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none">'
	.. '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
	.. "</svg>"

---Pre-render ```mermaid fences via mmdr, replacing them with HTML blocks.
---Failed renders leave the original fence untouched for browser-side fallback.
---@param text string Full markdown text
---@return string text Markdown with pre-rendered mermaid blocks
local function prerender_mermaid_blocks(text)
	local rust_idx = 0
	local out = {}
	local pos = 1

	while true do
		-- Find opening ```mermaid fence
		local fence_start, fence_end = text:find("\n```mermaid%s*\n", pos)
		if not fence_start then
			-- Also check at the very start of the document
			if pos == 1 then
				fence_start, fence_end = text:find("^```mermaid%s*\n")
			end
			if not fence_start then
				break
			end
		end

		-- Find closing ```
		local close_start, close_end = text:find("\n```%s*\n", fence_end)
		if not close_start then
			-- Try closing at end of file
			close_start, close_end = text:find("\n```%s*$", fence_end)
			if not close_start then
				break
			end
		end

		-- Extract mermaid source between fences
		local source = text:sub(fence_end + 1, close_start - 1)
		if source and #source > 0 then
			local svg, _err = render_mermaid_via_mmdr(source)
			if svg then
				rust_idx = rust_idx + 1
				local block_id = "mmd-rust-" .. rust_idx
				local encoded = vim.uri_encode(source, "rfc2396")

				local html_block = '<div class="mermaid-block mermaid-rendered" id="'
					.. block_id
					.. '" data-mermaid-source="'
					.. encoded
					.. '" data-graph="mermaid" data-prerendered="true">'
					.. '<button class="mermaid-expand-btn" title="Expand diagram" data-expand="'
					.. block_id
					.. '">'
					.. EXPAND_BTN_SVG
					.. "</button>"
					.. '<div class="mermaid-svg-wrap">'
					.. svg
					.. "</div>"
					.. "</div>"

				-- Append text before fence + the HTML block
				out[#out + 1] = text:sub(pos, fence_start - 1)
				out[#out + 1] = "\n" .. html_block .. "\n"
				pos = close_end + 1
			else
				-- mmdr failed for this block: leave fence untouched for JS fallback
				out[#out + 1] = text:sub(pos, close_end)
				pos = close_end + 1
			end
		else
			out[#out + 1] = text:sub(pos, close_end)
			pos = close_end + 1
		end
	end

	-- Append remaining text
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

-- Neovim reads a dotted filetype as each of its parts in turn (rzk.markdown
-- is rzk, then markdown), so a literate file whose filetype has a markdown
-- part previews whole with no config, as does a part filetypes names; the
-- whole name is read first for an entry that is itself dotted.
local function previews_whole(ft)
	if M._filetype_set[ft] then
		return true
	end
	for part in ft:gmatch("[^.]+") do
		if M._filetype_set[part] then
			return true
		end
	end
	return false
end

---Get the content to write based on filetype.
---Markdown buffers (a markdown part counts): entire buffer.
---Mermaid files (.mmd, .mermaid): entire buffer wrapped in mermaid fence.
---Others: mermaid block under cursor wrapped in fence.
---@param bufnr integer
---@return string
local function get_content(bufnr)
	local text
	local ft = vim.bo[bufnr].filetype
	if previews_whole(ft) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
	elseif vim.api.nvim_buf_get_name(bufnr):match("%.mmd$") or vim.api.nvim_buf_get_name(bufnr):match("%.mermaid$") then
		-- .mmd / .mermaid files: treat entire buffer as mermaid
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = "```mermaid\n" .. table.concat(lines, "\n") .. "\n```\n"
	else
		-- Other filetypes: extract mermaid block under cursor, wrap in code fence
		local mermaid_text = extract_mermaid_under_cursor(bufnr)
		text = "```mermaid\n" .. mermaid_text .. "\n```\n"
	end

	-- Pre-render mermaid blocks via mmdr if configured. Skipped when raw HTML
	-- is disabled: pre-rendering injects <svg> markup into content.md, which
	-- markdown-it would escape to literal text under html:false. The browser-
	-- side renderer handles the fences instead (it doesn't need raw HTML).
	if M.config.mermaid_renderer == "rust" and M.config.allow_raw_html ~= false and is_mmdr_available() then
		text = prerender_mermaid_blocks(text)
	end

	return text
end

---Same as get_content but never errors (returns nil on failure).
---@param bufnr integer
---@return string|nil
local function get_content_safe(bufnr)
	local ok, text = pcall(get_content, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function write_content(dir, text, bufnr)
	local path = vim.fs.joinpath(dir, M.config.content_name)
	util.write_text(path, text)
	-- Sidecar recording the source file's directory. The server's asset
	-- route resolves relative image paths against it; using a file (rather
	-- than server state) lets takeover secondaries retarget it by simply
	-- writing into the shared workspace.
	if bufnr then
		local name = vim.api.nvim_buf_get_name(bufnr)
		local src_dir = name ~= "" and vim.fs.dirname(name) or nil
		if src_dir and src_dir ~= "" then
			pcall(util.write_text, vim.fs.joinpath(dir, "asset_root"), src_dir)
		end
	end
	return path
end

---------------------------------------------------------------------------
-- Refresh logic
---------------------------------------------------------------------------

-- A push kitehost refused would be refused again on every edit or
-- cursor move, so each kind is told once per server.
local push_reported = setmetatable({}, { __mode = "k" })
local function report_push(what, pushed, err)
	local inst = M._server_instance
	if pushed or not inst then
		return
	end
	push_reported[inst] = push_reported[inst] or {}
	if push_reported[inst][what] then
		return
	end
	push_reported[inst][what] = true
	vim.notify(("mdkite: could not %s: %s"):format(what, tostring(err)), vim.log.levels.WARN)
end

-- A refusal repeats on every cursor move, so each kind is told once per primary port.
local remote_reported = {}
local function report_remote(what, port, cause)
	local key = what .. "@" .. tostring(port)
	if remote_reported[key] then
		return
	end
	remote_reported[key] = true
	vim.notify(("mdkite: could not %s: %s"):format(what, tostring(cause)), vim.log.levels.WARN)
end

local function maybe_refresh(bufnr, silent)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local text = get_content_safe(bufnr)
	if not text then
		return false
	end

	if M._last_text_by_buf[bufnr] == text then
		return false
	end

	local dir = M._workspace_dir or ensure_workspace(bufnr)
	write_content(dir, text, bufnr)
	M._last_text_by_buf[bufnr] = text

	-- Notify kitehost of the content change for immediate SSE push
	-- In secondary takeover mode, M._server_instance is nil: fs_watch handles reload
	if M._server_instance then
		report_push("reload the preview", pcall(server.reload, M._server_instance, M.config.content_name))
	end

	if not silent and M.config.notify_on_refresh then
		vim.notify("mdkite: preview updated", vim.log.levels.INFO)
	end
	return true
end

local function debounced_refresh(bufnr)
	M._debounce_seq = M._debounce_seq + 1
	local this_call = M._debounce_seq
	vim.defer_fn(function()
		if this_call ~= M._debounce_seq then
			return
		end
		pcall(maybe_refresh, bufnr, true)
	end, M.config.debounce_ms)
end

---------------------------------------------------------------------------
-- Scroll sync (line-based)
---------------------------------------------------------------------------

--- Send cursor line to browser for scroll sync.
local function send_scroll_sync(bufnr)
	if not M.config.scroll_sync then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
	if cursor_line == M._last_scroll_line then
		return
	end
	M._last_scroll_line = cursor_line
	local total = vim.api.nvim_buf_line_count(bufnr)
	local payload = vim.json.encode({ line = cursor_line - 1, total = total })
	if M._server_instance then
		report_push("sync the scroll", pcall(server.send_event, M._server_instance, "scroll", payload))
	elseif M._takeover_port then
		local port = M._takeover_port
		require("mdkite.remote").send_event(port, "scroll", payload, M._token, function(sent, cause)
			if not sent then
				vim.schedule(function()
					report_remote("sync the scroll", port, cause)
				end)
			end
		end)
	end
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds_for_buffer(bufnr)
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
	end
	M._augroup = vim.api.nvim_create_augroup("MdKiteAuto", { clear = true })

	if M.config.auto_refresh then
		for _, ev in ipairs(M.config.auto_refresh_events) do
			-- Called by pcall itself, so the API's message carries no Lua position.
			local made, err = pcall(vim.api.nvim_create_autocmd, ev, {
				group = M._augroup,
				buffer = bufnr,
				callback = function()
					debounced_refresh(bufnr)
				end,
				desc = "mdkite auto-refresh (debounced)",
			})
			if not made then
				error("auto_refresh_events: " .. tostring(err), 0)
			end
		end
	end

	for _, ev in ipairs({ "CursorMoved", "CursorMovedI" }) do
		vim.api.nvim_create_autocmd(ev, {
			group = M._augroup,
			buffer = bufnr,
			callback = function()
				send_scroll_sync(bufnr)
			end,
			desc = "mdkite scroll sync",
		})
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- When bound to 0.0.0.0 detect the outbound LAN IP via a UDP connect trick
-- (no packets are sent; it just lets the kernel pick the right interface).
local function lan_ip()
	local udp = vim.uv.new_udp()
	if not udp then
		return "127.0.0.1"
	end
	local ok = pcall(function()
		udp:connect("8.8.8.8", 80)
	end)
	local addr = ok and udp:getsockname()
	pcall(function()
		udp:close()
	end)
	return (addr and addr.ip) or "127.0.0.1"
end

local rule_reported = setmetatable({}, { __mode = "k" })

-- A server without the rule reports "::" as written, which shows as its loopback too.
local function wildcard_loopback(ip)
	if server.wildcard_loopback then
		-- A caller may replace the rule; one that raises must not fail a started server.
		local ruled, loopback = pcall(server.wildcard_loopback, ip)
		if ruled then
			return loopback
		end
		-- Every retarget builds a URL, so a rule that keeps raising is told once per server.
		local inst = M._server_instance or M
		if not rule_reported[inst] then
			rule_reported[inst] = true
			vim.notify(
				"mdkite: kitehost's wildcard rule raised, so the URL names the address bound: " .. tostring(loopback),
				vim.log.levels.WARN
			)
		end
		return nil
	end
	return ip == "::" and "::1" or nil
end

-- An IPv6 literal takes brackets, or its colons read as the port.
local function display_host(bound)
	-- 0.0.0.0 shows the LAN address a remote browser reaches, which no probe checks.
	if bound == "0.0.0.0" then
		return lan_ip()
	end
	local shown = wildcard_loopback(bound) or bound
	shown = shown:match("^::[fF][fF][fF][fF]:(%d+%.%d+%.%d+%.%d+)$") or shown
	if shown:find(":", 1, true) then
		shown = "[" .. shown .. "]"
	end
	return shown
end

-- Only a 127.0.0.1 bind's index carries the token, so any other bind's URL must.
local function browser_url(shown, port, bind_host)
	local base = ("http://%s:%d/"):format(shown, port)
	-- On a loopback bind the index carries the token (data-live-token), so
	-- the URL leaves it out of history, the address bar and a shared
	-- screen; any other bind's page has no other way to get it.
	if M._token and M._token ~= "" and not is_loopback(bind_host) then
		return base .. "?t=" .. M._token
	end
	return base
end

-- The URL is taken when scheduled: a stop before the timer fires takes the server it names.
local function open_later(url)
	local inst = M._server_instance
	vim.defer_fn(function()
		if M._server_instance == inst then
			util.open_in_browser(url, M.config.browser)
		end
	end, 200)
end

-- Shared by a stop and every failed start; the lock goes only when this instance wrote it.
local function forget_session()
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
		M._augroup = nil
	end
	if M._lock_owned then
		M._lock_owned = nil
		require("mdkite.lock").remove()
	end
	M._workspace_dir = nil
	M._last_scroll_line = nil
	M._is_primary = nil
	M._takeover_port = nil
	M._token = nil
	M._bound_host = nil
	-- A preview joined again may meet a primary restarted with another token.
	remote_reported = {}
end

-- A server left listening after a failure would serve the preview, token and all.
local function abandon(inst)
	pcall(server.stop, inst)
	if M._server_instance == inst then
		M._server_instance = nil
	end
	forget_session()
end

function M.start()
	-- The two plugins update apart, so an older server is refused before
	-- any state is made, naming the release this one needs.
	if not find_server() then
		vim.notify(
			("mdkite: requires kitehost.nvim %s or newer; install or update selimacerbas/kitehost.nvim"):format(
				KITEHOST_FLOOR
			),
			vim.log.levels.ERROR
		)
		return
	end
	for _, flag in ipairs(REQUIRED_FEATURES) do
		if not (server.features and server.features[flag]) then
			vim.notify(
				("mdkite: requires kitehost.nvim %s or newer, and the installed one lacks features.%s; update selimacerbas/kitehost.nvim"):format(
					KITEHOST_FLOOR,
					flag
				),
				vim.log.levels.ERROR
			)
			return
		end
	end
	local bufnr = vim.api.nvim_get_current_buf()
	-- What a retarget kitehost refuses goes back to.
	local served_dir = M._workspace_dir

	-- Takeover talks to 127.0.0.1, which a specific-interface bind does not answer on.
	if
		not M._server_instance
		and M.config.instance_mode == "takeover"
		and not is_loopback(M.config.host)
		and M.config.host ~= "0.0.0.0"
	then
		vim.notify(
			'mdkite: takeover mode supports host = "127.0.0.1", "localhost" or "0.0.0.0" only.\n'
				.. 'Use "0.0.0.0" for LAN access, or instance_mode = "multi" to bind a specific interface.',
			vim.log.levels.ERROR
		)
		return
	end

	local ok_content, text = pcall(get_content, bufnr)
	if not ok_content then
		vim.notify("mdkite: " .. tostring(text), vim.log.levels.ERROR)
		return
	end

	-- Resolve workspace: shared (takeover) or per-buffer (multi)
	local dir = M.config.instance_mode == "takeover" and util.shared_workspace() or resolve_workspace(bufnr)
	local made, mkdir_err = pcall(util.mkdirp, dir)
	if not made then
		-- A running server keeps its preview; anything else starts from nothing.
		if not M._server_instance then
			forget_session()
		end
		vim.notify(
			("mdkite: could not create the workspace %s: %s"):format(dir, tostring(mkdir_err)),
			vim.log.levels.ERROR
		)
		return
	end
	M._workspace_dir = dir

	-- Decide role + token BEFORE writing index.html. The index bakes the
	-- token in via the __LIVE_TOKEN__ placeholder, so we need it ready.
	if M.config.instance_mode == "takeover" and not M._server_instance then
		local lock = require("mdkite.lock")
		local lock_data, old = lock.holder()
		if old then
			-- An older release serves its preview from its own cache
			-- directory, which this one never writes, so a join could not reach
			-- it: it is named and left alone, and no start fights it for the port.
			forget_session()
			vim.notify(
				("mdkite: an older release's preview in another Neovim holds port %d: stop it there, then run :MdKite again"):format(
					lock_data.port
				),
				vim.log.levels.ERROR
			)
			return
		end
		if lock_data then
			-- Secondary: server is already running in another Neovim
			-- instance. Adopt its token so our scroll-sync RPC works. The
			-- primary's bind decides whether its index carries the token; a
			-- lock from an older primary has no host, so the URL keeps it.
			-- The URL names 127.0.0.1, where the probe above reached it.
			M._is_primary = false
			M._takeover_port = lock_data.port
			M._token = lock_data.token
			-- A raise after the role is taken would leave a half-joined session.
			local joined, join_err = pcall(function()
				-- Armed before the write: a join that fails must leave the primary's preview as it was.
				set_autocmds_for_buffer(bufnr)
				write_content(dir, text, bufnr)
				M._last_text_by_buf[bufnr] = text
				if type(M.config.hooks.on_start) == "function" then
					M.config.hooks.on_start(browser_url("127.0.0.1", lock_data.port, lock_data.host))
				end
			end)
			if not joined then
				forget_session()
				vim.notify("mdkite: could not join the running preview: " .. tostring(join_err), vim.log.levels.ERROR)
			end
			return
		end
		-- A lock is left for the write after the start: a probe that timed out may read a live primary as gone.
	end

	-- Primary path (takeover) or single-instance (multi). Generate a token
	-- once per server lifetime and reuse it across retargets.
	if not M._token or M._token == "" then
		local made, token = pcall(server_util.random_token, 16)
		if not made then
			forget_session()
			vim.notify("mdkite: could not make a session token: " .. tostring(token), vim.log.levels.ERROR)
			return
		end
		M._token = token
	end

	-- A fresh start may share its workspace with another instance's server, so nothing is written before one answers.
	local function publish()
		write_index_if_needed(dir)
		write_content(dir, text, bufnr)
		M._last_text_by_buf[bufnr] = text
	end

	-- Start kitehost's server if not already running
	if not M._server_instance then
		local port = effective_port()
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		local asked_host = M.config.host
		-- vim.pesc keeps a content_name or index_name with pattern characters exact.
		-- The write's temporaries (.<name>.<pid>.tmp) at any depth: the dot rule that hides them is the sibling's own.
		local protected = { "^/" .. vim.pesc(M.config.content_name) .. "$", "^/asset_root$", "/%.[^/]+%.%d+%.tmp$" }
		if not is_loopback(asked_host) then
			-- Any other bind's index is gated too; the ?t= URL unlocks it.
			table.insert(protected, "^/$")
			table.insert(protected, "^/" .. vim.pesc(M.config.index_name) .. "$")
		end
		local ok, inst = pcall(server.start, {
			port = port,
			host = asked_host,
			root = dir,
			default_index = index_path,
			headers = { ["Cache-Control"] = "no-cache" },
			-- No cors: the preview page is same-origin and remote.lua talks raw
			-- TCP. A wildcard ACAO would let any website in the user's browser
			-- read the token out of the (unauthenticated) index page.
			live = {
				enabled = true,
				inject_script = false,
				debounce = 100,
			},
			features = { dirlist = { enabled = false } },
			token = M._token,
			protected_paths = protected,
			-- Resolve relative image paths against the source file's dir
			-- (issue #17). Read per request so takeover secondaries and
			-- buffer switches retarget it via the sidecar.
			asset_root = function()
				local ws = M._workspace_dir
				if not ws then
					return nil
				end
				local ok_read, data = pcall(util.read_text, vim.fs.joinpath(ws, "asset_root"))
				if not ok_read or not data or data == "" then
					return nil
				end
				return (data:gsub("%s+$", ""))
			end,
		})
		if not ok then
			forget_session()
			local reason = tostring(inst)
			local msg = ("mdkite: failed to start server (port %s): %s"):format(tostring(port), reason)
			-- Every held-port refusal carries luv's text; a port the OS chose is named only in the reason.
			if port ~= 0 and reason:find("EADDRINUSE: address already in use", 1, true) then
				msg = (
					"mdkite: port %s is in use by another program. Set port to a free one in setup(), "
					.. 'or port = 0 with instance_mode = "multi" for an OS-assigned port.'
				):format(tostring(port))
				-- A probe that timed out reads a live primary as gone; its lock still names the port.
				local held, old
				if M.config.instance_mode == "takeover" then
					held, old = require("mdkite.lock").holder()
				end
				-- A stale lock names the port too; only a holder that takes its lock's token gets the hint.
				if held and held.port == port and old then
					msg = msg
						.. " An older release's preview in another Neovim may hold it: stop it there, then run :MdKite again."
				elseif held and held.port == port then
					msg = msg .. " Another Neovim's preview may hold it: run :MdKite again to join it."
				end
			end
			vim.notify(msg, vim.log.levels.ERROR)
			return
		end
		-- A setup() may change the host while the server runs; what it bound does not change.
		M._bound_host = inst.host or asked_host
		-- A raise past the listen left a listening server, a raw Lua error and no browser.
		local finished, finish_err = pcall(function()
			publish()
			-- The lock names the port the server got.
			if M.config.instance_mode == "takeover" then
				-- Owned from the write on: a write that fails may leave the file it opened.
				M._lock_owned = true
				require("mdkite.lock").write(inst.port, dir, M._token, M._bound_host)
			end
			-- Armed last, so a failed start leaves no autocmd refreshing nothing.
			set_autocmds_for_buffer(bufnr)
		end)
		if not finished then
			abandon(inst)
			vim.notify(
				("mdkite: failed to start server (port %s): %s"):format(tostring(inst.port), tostring(finish_err)),
				vim.log.levels.ERROR
			)
			return
		end
		M._server_instance = inst
		M._is_primary = true
		M._takeover_port = nil

		local url = browser_url(display_host(M._bound_host), inst.port, M._bound_host)
		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(url)
		end

		if M.config.open_browser then
			open_later(url)
		end
	else
		-- Server already running, retarget to this buffer's workspace
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		local retargeted, watching = pcall(server.update_target, M._server_instance, dir, index_path)
		if not retargeted then
			-- The server still serves the last workspace, so the preview
			-- and its autocmds stay with it.
			M._workspace_dir = served_dir
			vim.notify("mdkite: could not retarget: " .. tostring(watching), vim.log.levels.ERROR)
			return
		end
		local inst = M._server_instance
		local published, publish_err = pcall(publish)
		if not published then
			-- The last buffer stays armed, so the server goes back to what it served.
			M._workspace_dir = served_dir
			-- Takeover's workspace is the one just written, so the next refresh rewrites it.
			M._last_text_by_buf = {}
			local back, back_err =
				pcall(server.update_target, inst, served_dir, vim.fs.joinpath(served_dir, M.config.index_name))
			if not back then
				abandon(inst)
				vim.notify(
					("mdkite: could not retarget: %s; the server could not go back and is stopped: %s"):format(
						tostring(publish_err),
						tostring(back_err)
					),
					vim.log.levels.ERROR
				)
				return
			end
			vim.notify("mdkite: could not retarget: " .. tostring(publish_err), vim.log.levels.ERROR)
			return
		end
		-- The last buffer's autocmds went with the group: nothing would refresh the preview.
		local armed, arm_err = pcall(set_autocmds_for_buffer, bufnr)
		if not armed then
			abandon(inst)
			vim.notify(
				("mdkite: could not retarget: %s; the server is stopped"):format(tostring(arm_err)),
				vim.log.levels.ERROR
			)
			return
		end
		-- An edit here still refreshes: this plugin pushes its own reload.
		if watching == false then
			vim.notify(
				"mdkite: the server reports file watching off; changes made outside this editor may not refresh the preview",
				vim.log.levels.WARN
			)
		end
		report_push("reload the preview", pcall(server.reload, M._server_instance, M.config.content_name))

		local url = browser_url(display_host(M._bound_host), inst.port, M._bound_host)
		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(url)
		end

		-- No browser tab connected (user closed it)? Re-open.
		if M.config.open_browser and server.connected_client_count(inst) == 0 then
			open_later(url)
		end
	end
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	local changed = maybe_refresh(bufnr, false)
	if not changed and M.config.notify_on_refresh then
		vim.notify("mdkite: no changes detected", vim.log.levels.INFO)
	end
end

function M.stop()
	if M._server_instance then
		pcall(server.stop, M._server_instance)
		M._server_instance = nil
	end
	forget_session()

	if type(M.config.hooks.on_stop) == "function" then
		M.config.hooks.on_stop()
	end
end

-- A joined preview runs no server of its own, so its role says it runs.
function M.toggle()
	if M._server_instance or M._is_primary == false then
		M.stop()
	else
		M.start()
	end
end

return M
