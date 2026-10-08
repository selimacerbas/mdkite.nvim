-- tests/token_auth_test.lua
-- End-to-end check that the plugin generates a token, threads it into the
-- served HTML and gates content.md, that the lockfile holding it is
-- private, and (Section 6) that the preview URL names the address the
-- server bound and carries the token on any bind but 127.0.0.1. Section 2b
-- checks the index's baked source path: it names the previewed file, and a
-- retarget to one with HTML-special bytes in its name rewrites the
-- persisted index with the path escaped. The suite
-- drives require("mdkite").start() directly, not the
-- :MdKite user command.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/token_auth_test.lua"
-- kitehost.nvim is found by tests/helpers.lua ($KITEHOST_RTP,
-- ./kitehost-rtp, the checkout's sibling kitehost.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
-- Where the plugin would write without the helper: the cache Neovim started
-- with (the runner's own under tests/run.sh), and ~/.cache/nvim.
local startup_caches = { vim.fn.stdpath("cache"), vim.fs.normalize("~/.cache/nvim") }
H.isolate()
local server_dir = H.rtp()

local tmpdir = H.tmpdir()
local mdfile = vim.fs.joinpath(tmpdir, "test.md")
H.write_file(mdfile, "# hello\n\nbody text here.\n")

vim.cmd("edit " .. vim.fn.fnameescape(mdfile))
vim.bo.filetype = "markdown"

local mp = require("mdkite")
-- Sections 0 to 2 run multi mode, a server on an OS-assigned port; the lock
-- sections (3 to 5) write it or start takeover themselves, on a free port,
-- never the shared 8421.
mp.setup({
	open_browser = false,
	instance_mode = "multi",
})
mp.start()

local ok, eq, http_get = H.ok, H.eq, H.http_get

-- H.isolate raises when stdpath does not follow the variables; what it cannot
-- see is where the plugin writes.
H.section("Section 0: isolation")
-- joinpath writes / where stdpath keeps Windows's backslashes, so both names
-- are compared canonical: a .. in the workspace resolves through the
-- filesystem before the prefix test (a lexical walk of its parents passed
-- <cache>/../escape, measured), the separator keeps a sibling such as
-- <cache>x out, and case folds where the filesystem folds, as H.same_path's
-- does.
local workspace = mp._workspace_dir or ""
local function sits_under(path, dir)
	local p, d = H.canon(path), H.canon(dir) .. "/"
	if H.fs_folds_case then
		p, d = p:lower(), d:lower()
	end
	return vim.startswith(p, d)
end
ok(
	workspace ~= "" and sits_under(workspace, vim.fn.stdpath("cache")),
	"the plugin's workspace sits under the isolated cache: " .. workspace
)
ok(
	not sits_under(vim.fs.joinpath(vim.fn.stdpath("cache"), "..", "escape", "mdkite"), vim.fn.stdpath("cache")),
	"a workspace that climbs out of the cache with .. does not sit under it"
)
ok(
	not sits_under(vim.fn.stdpath("cache") .. "x/mdkite", vim.fn.stdpath("cache")),
	"a sibling whose name starts with the cache's does not sit under it"
)
local written = {}
for _, cache in ipairs(startup_caches) do
	local dir = vim.fs.joinpath(cache, "mdkite", vim.fs.basename(workspace))
	if vim.fn.isdirectory(dir) == 1 then
		table.insert(written, dir)
	end
end
eq(table.concat(written, ", "), "", "nothing was written under the cache Neovim started with or ~/.cache/nvim")

H.section("Section 1: start")

-- Server instance + token must exist
ok(mp._server_instance ~= nil, "server instance created")
ok(type(mp._token) == "string" and #mp._token == 32, "_token is 32 hex chars")
ok(mp._token:match("^[0-9a-f]+$") ~= nil, "_token is pure hex")

local port = mp._server_instance.port
ok(type(port) == "number" and port > 0, "server bound to a port")

-- Static index reachable without token
local r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.status, 200, "/ (index) is 200 without token")
ok(
	r.body:find('data%-live%-token="' .. mp._token .. '"') ~= nil,
	"index.html has data-live-token attribute set to current token"
)

-- content.md is gated
r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
eq(r.status, 401, "/content.md without token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=wrong"):format(port))
eq(r.status, 401, "/content.md with a wrong token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token))
eq(r.status, 200, "/content.md with correct token is 200")
ok(r.body:find("hello") ~= nil, "/content.md body contains buffer text")

-- A DNS-rebinding page reaches 127.0.0.1 under its own name, and the
-- loopback index carries the token, so kitehost's Host check is what
-- keeps the page out.
r = http_get(("http://127.0.0.1:%d/"):format(port), { "Host: rebind.example" })
eq(r.status, 421, "the index under a foreign Host is 421")
ok(not r.body:find(mp._token, 1, true), "and its answer carries no token")
r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token), { "Host: rebind.example" })
eq(r.status, 421, "content.md with the token under a foreign Host is 421")
r = http_get(("http://127.0.0.1:%d/"):format(port), { "Host: localhost:9999" })
eq(r.status, 200, "an ssh -L tunnel's Host (localhost, another port) is served")

H.section("Section 2: stop and verify cleanup")
mp.stop()
ok(mp._token == nil, "_token cleared after stop")
ok(mp._server_instance == nil, "_server_instance cleared after stop")

-- Refused is curl 7; a socket left bound and silent is curl 28, which a
-- status of 0 alone passed (measured). Give the close a moment. The first
-- hosted Windows run read 28 here, taken as its two-second retry of a
-- refused loopback connect, which H.http_get's connect bound now waits out;
-- the hosted Windows runs since read 7 there (measured).
vim.wait(200, function()
	return false
end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.curl_exit, 7, "the port refuses connections after stop")

H.section("Section 2b: the baked source path")
-- The index bakes the previewed file's display path for the header, and a
-- path with HTML-special bytes is escaped inside the attribute. A fixed
-- workspace_dir makes the second start a retarget of the same directory,
-- where overwrite_index_on_start = false leaves the persisted index to the
-- staleness check, which must rewrite it for the new path.
mp.setup({
	open_browser = false,
	instance_mode = "multi",
	workspace_dir = vim.fs.joinpath(tmpdir, "ws"),
	overwrite_index_on_start = false,
})
mp.start()
local r2b = http_get(("http://127.0.0.1:%d/"):format(mp._server_instance.port))
ok(r2b.body:find('data-source-path="test.md"', 1, true) ~= nil, "the served index names the previewed file")
mp.stop()

local weird = vim.fs.joinpath(tmpdir, "we&ird.md")
H.write_file(weird, "# weird\n")
vim.cmd("edit " .. vim.fn.fnameescape(weird))
vim.bo.filetype = "markdown"
mp.start()
local r2c = http_get(("http://127.0.0.1:%d/"):format(mp._server_instance.port))
ok(
	r2c.body:find('data-source-path="test.md"', 1, true) == nil,
	"the staleness check rewrote the persisted index for the new file"
)
ok(
	r2c.body:find('data-source-path="we&amp;ird.md"', 1, true) ~= nil,
	"the baked path escapes the ampersand in the attribute"
)
mp.stop()
vim.cmd("edit " .. vim.fn.fnameescape(mdfile))

H.section("Section 3: the lockfile keeps the token private")
-- The lockfile carries the session token and the README promises 0600, but
-- the open's mode applies only when it creates the file, so a direct write
-- over a 0644 file kept that mode (measured) until lock.write made it
-- private before writing the token.
local uv = vim.uv
local lock = require("mdkite.lock")
local lock_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "mdkite", "server.lock")
local function mode()
	local stat = uv.fs_stat(lock_file)
	return stat and ("%o"):format(stat.mode % 512) or "missing"
end
if vim.fn.has("win32") == 1 then
	H.skip("a fresh lockfile is 0600 (no POSIX mode bits on Windows)")
	H.skip("a 0644 lockfile is 0600 after lock.write (no POSIX mode bits on Windows)")
else
	lock.remove()
	lock.write(1234, "/w", "TOKEN")
	eq(mode(), "600", "a fresh lockfile is 0600")
	uv.fs_chmod(lock_file, 420)
	lock.write(1234, "/w", "TOKEN")
	eq(mode(), "600", "a 0644 lockfile is 0600 after lock.write")
	lock.remove()
end

-- A port free a moment ago: the takeover port is 8421 unless cfg.port names
-- one (measured in effective_port), and a fixed port would collide with a
-- preview the developer has open.
local function free_port()
	local probe = uv.new_tcp()
	probe:bind("127.0.0.1", 0)
	local p = probe:getsockname().port
	probe:close()
	return p
end
local function read_lock()
	local fd = uv.fs_open(lock_file, "r", 420)
	if not fd then
		return nil
	end
	local data = uv.fs_read(fd, uv.fs_fstat(fd).size, 0)
	uv.fs_close(fd)
	local decoded, tbl = pcall(vim.json.decode, data or "")
	return decoded and tbl or nil
end

H.section("Section 4: the default takeover mode, end to end")
-- Every other start in the suites runs multi, so the default path (the lock
-- election, the lock with the token, a second instance adopting the
-- primary, stop removing the lock) met no gate.
local tport = free_port()
-- The suite's first setup chose multi, and setup merges into the current
-- configuration, so takeover is named here; the second instance below
-- starts from the defaults.
mp.setup({ open_browser = false, instance_mode = "takeover", port = tport })
mp.start()
eq(mp._is_primary, true, "the first takeover start is the primary")
local tinst_port = mp._server_instance and mp._server_instance.port
eq(tinst_port, tport, "the primary serves the configured port")
local held = read_lock()
ok(
	held ~= nil and held.port == tport and held.token == mp._token and held.pid == vim.fn.getpid(),
	"the lock names the port, the session token and this process: " .. vim.inspect(held)
)
if vim.fn.has("win32") == 1 then
	H.skip("the takeover lock is 0600 (no POSIX mode bits on Windows)")
else
	eq(mode(), "600", "the takeover lock is 0600")
end
r = http_get(("http://127.0.0.1:%d/?t=%s"):format(tport, mp._token or ""))
eq(r.status, 200, "the primary answers the tokenized index")
r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(tport, mp._token or ""))
ok(r.status == 200 and r.body:find("hello", 1, true) ~= nil, "the primary serves the buffer with the token")
-- A second Neovim takes the secondary path: the lock's server answers, so
-- it adopts the primary's port and token instead of starting a server.
local second = vim.fs.joinpath(H.tmpdir(), "second.lua")
H.write_file(
	second,
	([[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("mdkite")
mp.setup({ open_browser = false, port = %d })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
io.stdout:write(vim.json.encode({ primary = mp._is_primary, port = mp._takeover_port, token = mp._token, server = mp._server_instance ~= nil }) .. "\n")
mp.stop()
vim.cmd("qa!")
]]):format(server_dir, H.root, tport, mdfile)
)
local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", second }, { timeout = 30000 }):wait()
local adopted = (child.stdout or ""):match("({.-})%s*$")
local seen = adopted and select(2, pcall(vim.json.decode, adopted)) or nil
ok(
	type(seen) == "table"
		and seen.primary == false
		and seen.port == tport
		and seen.token == mp._token
		and seen.server == false,
	"a second instance adopts the primary's port and token: "
		.. vim.inspect(seen or ((child.stdout or "") .. (child.stderr or "")))
)
ok(read_lock() ~= nil, "a secondary's stop leaves the primary's lock")
mp.stop()
ok(uv.fs_stat(lock_file) == nil, "the primary's stop removes the lock")

H.section("Section 5: a lock that cannot be made private stops the start")
-- lock.write refuses a file it cannot make private; the refusal came after
-- the server was up, which left it listening with an empty lock, a raw
-- Lua error and no browser.
local fport = free_port()
local real_fchmod = uv.fs_fchmod
uv.fs_fchmod = function()
	return nil, "EPERM: operation not permitted (stubbed)"
end
mp.setup({ open_browser = false, instance_mode = "takeover", port = fport })
local raised, raise_err
local notified = H.expect_error(
	"failed to start server (port " .. fport .. "): cannot make the lock file private",
	function()
		local done, err = pcall(mp.start)
		raised, raise_err = not done, err
	end
)
uv.fs_fchmod = real_fchmod
eq(raised and ("raised: " .. tostring(raise_err)) or "returned", "returned", "start() returns instead of raising")
ok(notified, "the start-failure notification names the port and the reason")
eq(mp._server_instance, nil, "no server instance is kept")
r = http_get(("http://127.0.0.1:%d/"):format(fport))
eq(r.curl_exit, 7, "the port refuses connections: no server is left")
ok(uv.fs_stat(lock_file) == nil, "no lock is left")
mp.stop()

H.section("Section 6: the preview URL")
-- Every row reads the URL on_start receives: its host is the address the
-- server bound as a browser reaches it, and the token rides along on any
-- bind but 127.0.0.1, whose index carries it.
-- The URL on_start receives for a start on host; "" when none came. With
-- fetch, also what that URL answers and the session's token, read before
-- the stop.
local function url_for(host, fetch)
	local url
	mp.setup({
		open_browser = false,
		instance_mode = "multi",
		port = 0,
		host = host,
		hooks = {
			on_start = function(u)
				url = u
			end,
		},
	})
	mp.start()
	local page, token
	if fetch and url then
		page, token = http_get(url), mp._token
	end
	mp.stop()
	return url or "", page or { status = 0, body = "" }, token
end
-- An IPv6 literal takes brackets, or its colons read as the port.
local probe = uv.new_tcp()
local v6 = probe:bind("::1", 0)
probe:close()
if v6 then
	-- The token follows the bracket: a ::1 index is gated, so a URL without it answers 401.
	local v6_url = url_for("::1")
	ok(
		v6_url:match("^http://%[::1%]:%d+/%?t=%x+$") ~= nil,
		"an IPv6 loopback bind yields http://[::1]:<port>/?t=<token>: " .. v6_url
	)
	-- The IPv6 wildcard shows its loopback, as kitehost's own URL does.
	local any_url = url_for("::")
	ok(
		any_url:match("^http://%[::1%]:%d+/%?t=%x+$") ~= nil,
		"an IPv6 wildcard bind yields http://[::1]:<port>/?t=<token>: " .. any_url
	)
	-- Any spelling of the wildcard is bound as "::", so it opens [::1] too.
	local long_url = url_for("0:0:0:0:0:0:0:0")
	ok(
		long_url:match("^http://%[::1%]:%d+/%?t=%x+$") ~= nil,
		"a 0:0:0:0:0:0:0:0 bind yields http://[::1]:<port>/?t=<token>: " .. long_url
	)
	-- The loopback set stays 127.0.0.1 and localhost, the address takeover talks to.
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0, host = "::1" })
	mp.start()
	local v6_port = mp._server_instance and mp._server_instance.port or 0
	local bare = http_get(("http://[::1]:%d/"):format(v6_port))
	local keyed = http_get(("http://[::1]:%d/?t=%s"):format(v6_port, mp._token or ""))
	mp.stop()
	ok(
		bare.status == 401 and keyed.status == 200,
		("a ::1 bind answers 401 without the token and 200 with it: %d, %d"):format(bare.status, keyed.status)
	)
	local baked = keyed.body:match('data%-live%-token="([^"]*)"')
	eq(baked, "", "a ::1 bind bakes no token into its index")
else
	H.skip("an IPv6 loopback bind yields http://[::1]:<port>/?t=<token> (no IPv6 loopback here)")
	H.skip("an IPv6 wildcard bind yields http://[::1]:<port>/?t=<token> (no IPv6 loopback here)")
	H.skip("a 0:0:0:0:0:0:0:0 bind yields http://[::1]:<port>/?t=<token> (no IPv6 loopback here)")
	H.skip("a ::1 bind answers 401 without the token and 200 with it (no IPv6 loopback here)")
	H.skip("a ::1 bind bakes no token into its index (no IPv6 loopback here)")
end

-- On a loopback bind the index carries the token, so the URL does not;
-- a network bind's page has no other source.
local loop_url = url_for("127.0.0.1")
ok(loop_url:match("^http://127%.0%.0%.1:%d+/$") ~= nil, "a loopback bind's URL has no ?t=: " .. loop_url)
-- libuv binds IP literals only, and the floor binds localhost as
-- 127.0.0.1, where a server before it raised; a browser tries
-- localhost's ::1 first, where another program may listen, so the URL
-- names the address bound.
local localhost_url, localhost_page, localhost_token = url_for("localhost", true)
ok(
	localhost_url:match("^http://127%.0%.0%.1:%d+/$") ~= nil,
	"a localhost bind opens 127.0.0.1 with no ?t=: " .. localhost_url
)
-- The URL can drop the token only while the index carries it: a gated
-- index would open a 401 page on every localhost preview.
eq(localhost_page.status, 200, "the page a localhost bind opens answers 200")
local localhost_baked = localhost_page.body:match('data%-live%-token="([^"]*)"')
ok(
	localhost_token ~= nil and localhost_baked == localhost_token,
	"and its index carries the session's token: " .. tostring(localhost_baked)
)
local net_url = url_for("0.0.0.0")
ok(net_url:find("?t=", 1, true) ~= nil, "a network bind's URL keeps ?t=: " .. net_url)
-- An IPv4-mapped bind is named by its IPv4 address, and it is no 127.0.0.1
-- bind, so its index is gated and the URL keeps the token.
local mapped_probe = uv.new_tcp()
local mapped_bound, mapped_err = mapped_probe:bind("::ffff:127.0.0.1", 0)
mapped_probe:close()
if mapped_bound then
	local mapped_url = url_for("::ffff:127.0.0.1")
	ok(
		mapped_url:match("^http://127%.0%.0%.1:%d+/%?t=%x+$") ~= nil,
		"a ::ffff:127.0.0.1 bind opens http://127.0.0.1:<port>/?t=<token>: " .. mapped_url
	)
else
	H.skip(
		"a ::ffff:127.0.0.1 bind opens http://127.0.0.1:<port>/?t=<token> (the bind fails: "
			.. tostring(mapped_err)
			.. ")"
	)
end

-- lan_ip() names the address a UDP connect picks; a fake socket picks it here.
local function lan_reads(ip)
	local real = uv.new_udp
	uv.new_udp = function()
		return {
			connect = function()
				return 0
			end,
			getsockname = function()
				return { ip = ip }
			end,
			close = function() end,
		}
	end
	H.defer(function()
		uv.new_udp = real
	end)
end

H.case("Section 6b: a wildcard bind opens the LAN address with the token", function()
	lan_reads("192.0.2.7")
	local url = url_for("0.0.0.0")
	ok(url:match("^http://192%.0%.2%.7:%d+/%?t=%x+$") ~= nil, "a 0.0.0.0 bind opens the LAN address with ?t=: " .. url)
end)

H.case("Section 6c: a host changed while the server runs leaves the URL to the bound address", function()
	lan_reads("127.0.0.1")
	local url
	mp.setup({
		open_browser = false,
		instance_mode = "multi",
		port = 0,
		host = "0.0.0.0",
		hooks = {
			on_start = function(u)
				url = u
			end,
		},
	})
	mp.start()
	H.defer(mp.stop)
	local other = vim.fs.joinpath(tmpdir, "other.md")
	H.write_file(other, "# other\n")
	vim.cmd("edit " .. vim.fn.fnameescape(other))
	vim.bo.filetype = "markdown"
	H.defer(function()
		vim.cmd("edit " .. vim.fn.fnameescape(mdfile))
	end)
	mp.setup({ host = "127.0.0.1" })
	url = nil
	mp.start()
	url = url or ""
	local got = url ~= "" and http_get(url) or { status = 0 }
	ok(
		url:find("?t=", 1, true) ~= nil and got.status == 200,
		('a retarget after setup({ host = "127.0.0.1" }) keeps ?t= and answers 200: %s, %d'):format(url, got.status)
	)
	eq(got.body:match('data%-live%-token="([^"]*)"'), "", "the retargeted index bakes no token")
end)

-- The stream's status for the token a page at url is handed, 0 when none.
local function stream_status_for(port, token)
	if token == "" then
		return 0
	end
	local c, cerr = H.raw_connect(port)
	if not c then
		H.write_line("connect failed: " .. tostring(cerr))
		return 0
	end
	local status = 0
	local sent, serr = c:send(("GET /__live/events?t=%s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(token, port))
	if sent then
		local head = c:read(3000, function(b)
			return b:find("\r\n\r\n", 1, true) ~= nil
		end)
		local first = H.responses(head)[1]
		status = first and first.status or 0
	else
		H.write_line("send failed: " .. tostring(serr))
	end
	c:close()
	return status
end

H.case("Section 6d: a host changed while the server runs leaves the bake to the bound address", function()
	local url
	mp.setup({
		open_browser = false,
		instance_mode = "multi",
		port = 0,
		host = "127.0.0.1",
		hooks = {
			on_start = function(u)
				url = u
			end,
		},
	})
	mp.start()
	H.defer(mp.stop)
	local port = mp._server_instance and mp._server_instance.port or 0
	local other = vim.fs.joinpath(tmpdir, "other.md")
	H.write_file(other, "# other\n")
	vim.cmd("edit " .. vim.fn.fnameescape(other))
	vim.bo.filetype = "markdown"
	H.defer(function()
		vim.cmd("edit " .. vim.fn.fnameescape(mdfile))
	end)
	mp.setup({ host = "0.0.0.0" })
	url = nil
	mp.start()
	url = url or ""
	local page = url ~= "" and http_get(url) or { status = 0, body = "" }
	local baked = page.body:match('data%-live%-token="([^"]*)"') or ""
	ok(
		not url:find("t=", 1, true) and page.status == 200 and baked == mp._token,
		("the retarget's tokenless URL opens an index that bakes the token: %s, %d, %s"):format(
			url,
			page.status,
			baked ~= "" and "token baked" or "no token baked"
		)
	)
	eq(stream_status_for(port, baked), 200, "the stream opens with the baked token")
end)
-- The tokenless URL still opens a page whose stream authenticates, with the
-- token the served index hands the page.
local opened
mp.setup({
	open_browser = false,
	instance_mode = "multi",
	port = 0,
	host = "127.0.0.1",
	hooks = {
		on_start = function(u)
			opened = u
		end,
	},
})
mp.start()
opened = opened or ""
local open_port = tonumber(opened:match("^http://127%.0%.0%.1:(%d+)/")) or 0
local page = http_get(opened)
local handed = page.body:match('data%-live%-token="([^"]*)"') or ""
local stream_status = 0
if open_port > 0 and handed ~= "" then
	local c, cerr = H.raw_connect(open_port)
	if c then
		local sent, serr =
			c:send(("GET /__live/events?t=%s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(handed, open_port))
		if sent then
			local head = c:read(3000, function(b)
				return b:find("\r\n\r\n", 1, true) ~= nil
			end)
			local first = H.responses(head)[1]
			stream_status = first and first.status or 0
		else
			H.write_line("send failed: " .. tostring(serr))
		end
		c:close()
	else
		H.write_line("connect failed: " .. tostring(cerr))
	end
end
mp.stop()
ok(
	not opened:find("t=", 1, true) and page.status == 200 and handed ~= "" and stream_status == 200,
	("the tokenless URL opens a page whose stream takes the token its index hands it: %s, %d, %s, %d"):format(
		opened,
		page.status,
		handed ~= "" and "token baked" or "no token baked",
		stream_status
	)
)

-- A takeover secondary serves nothing: its URL's token follows the bind of
-- the primary that serves the page, whatever the secondary's own host.
local function secondary_url(primary_host, drop_host)
	local sport = free_port()
	mp.setup({ open_browser = false, instance_mode = "takeover", port = sport, host = primary_host, hooks = {} })
	mp.start()
	if drop_host then
		-- The lock an older primary wrote: the same fields, no host.
		local older = read_lock() or {}
		older.host = nil
		H.write_file(lock_file, vim.json.encode(older))
	end
	local script = vim.fs.joinpath(H.tmpdir(), "secondary.lua")
	H.write_file(
		script,
		([[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("mdkite")
local url = ""
mp.setup({ open_browser = false, port = %d, host = "127.0.0.1", hooks = { on_start = function(u) url = u end } })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
io.stdout:write(vim.json.encode({ primary = mp._is_primary, url = url }) .. "\n")
mp.stop()
vim.cmd("qa!")
]]):format(server_dir, H.root, sport, mdfile)
	)
	local run = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { timeout = 30000 }):wait()
	local line = (run.stdout or ""):match("({.-})%s*$")
	local got = line and select(2, pcall(vim.json.decode, line)) or nil
	local surl = (type(got) == "table" and got.primary == false and got.url) or ""
	local status = surl ~= "" and http_get(surl).status or 0
	mp.stop()
	return surl, status, (run.stdout or "") .. (run.stderr or "")
end
local wide_url, wide_status, wide_out = secondary_url("0.0.0.0")
ok(
	wide_url:match("^http://127%.0%.0%.1:%d+/%?t=%x+$") ~= nil and wide_status == 200,
	("a 127.0.0.1 secondary of a 0.0.0.0 primary gets a ?t= URL that answers 200: %s, %d %s"):format(
		wide_url,
		wide_status,
		wide_url == "" and wide_out or ""
	)
)
local loop_sec_url, loop_sec_status, loop_sec_out = secondary_url("127.0.0.1")
ok(
	loop_sec_url:match("^http://127%.0%.0%.1:%d+/$") ~= nil and loop_sec_status == 200,
	("a secondary of a 127.0.0.1 primary gets the tokenless URL that answers 200: %s, %d %s"):format(
		loop_sec_url,
		loop_sec_status,
		loop_sec_url == "" and loop_sec_out or ""
	)
)
-- A primary that predates the host field still runs; its URL must work.
local old_url, old_status, old_out = secondary_url("127.0.0.1", true)
ok(
	old_url:match("^http://127%.0%.0%.1:%d+/%?t=%x+$") ~= nil and old_status == 200,
	("a lock without the host field gives a ?t= URL that answers 200: %s, %d %s"):format(
		old_url,
		old_status,
		old_url == "" and old_out or ""
	)
)

H.finish()
