-- tests/command_test.lua
-- :MdKite runs the subcommand its first argument names, and start when it
-- names none; completion offers the subcommands for that argument alone; an
-- unknown subcommand is one error notice naming the known ones, and an
-- argument after a known one is one error saying it takes none. The
-- commands from before the rename run their subcommand and warn once a
-- session each. Sections 5 and 6 drive toggle against a real server: it
-- starts a stopped preview and stops a running one, a preview joined to
-- another Neovim's included. Sections 7 to 10 start real previews too: a
-- buffer whose dotted filetype has a markdown part, first or last, is
-- served whole, as is one setup's filetypes lists, beside markdown and in
-- place of an earlier setup's list; setup refuses a filetypes that is not
-- a list of names with one error and changes nothing; and a refresh reads
-- the set setup built instead of building its own.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/command_test.lua"
-- kitehost.nvim is found by tests/helpers.lua ($KITEHOST_RTP,
-- ./kitehost-rtp, the checkout's sibling kitehost.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
local server_dir = H.rtp()
local eq, ok = H.eq, H.ok

vim.cmd("source " .. vim.fn.fnameescape(H.root .. "/plugin/mdkite.lua"))
local mp = require("mdkite")
local SUBCOMMANDS = { "start", "stop", "refresh", "toggle" }
local FORWARDED = { MarkdownPreview = "start", MarkdownPreviewRefresh = "refresh", MarkdownPreviewStop = "stop" }

-- Runs cmdline with each function a subcommand reaches recorded instead of
-- run; the names called, in order, and the notices made.
local function dispatched(cmdline)
	local called, notes = {}, {}
	local real, real_notify = {}, vim.notify
	for _, name in ipairs(SUBCOMMANDS) do
		real[name] = mp[name]
		mp[name] = function()
			table.insert(called, name)
		end
	end
	vim.notify = function(msg, level)
		table.insert(notes, { msg = msg, level = level })
	end
	local ran, err = pcall(vim.cmd, cmdline)
	vim.notify = real_notify
	for name, fn in pairs(real) do
		mp[name] = fn
	end
	if not ran then
		error(vim.inspect(cmdline) .. " raised: " .. tostring(err), 0)
	end
	return table.concat(called, " "), notes
end

H.case("Section 1: each subcommand runs its function", function()
	for _, sub in ipairs(SUBCOMMANDS) do
		local called, notes = dispatched("MdKite " .. sub)
		eq(called, sub, ":MdKite " .. sub .. " runs " .. sub)
		eq(#notes, 0, ":MdKite " .. sub .. " adds no notice of its own")
	end
	eq((dispatched("MdKite")), "start", "a bare :MdKite runs start")
end)

H.case("Section 2: an unknown subcommand, or an argument after one, is one error", function()
	for _, case in ipairs({
		{ "MdKite nope", "mdkite: no subcommand nope; the subcommands are start, stop, refresh, toggle" },
		{ "MdKite nope extra", "mdkite: no subcommand nope; the subcommands are start, stop, refresh, toggle" },
		{ "MdKite start extra", "mdkite: start takes no arguments" },
		-- A control character typed into the name is shown as ?, so the notice stays one clean line.
		{ "MdKite no\1pe", "mdkite: no subcommand no?pe; the subcommands are start, stop, refresh, toggle" },
	}) do
		local cmdline, want = case[1], case[2]
		-- Quoted and escaped, so a control character in a line never reaches the output raw.
		local label = vim.inspect(cmdline)
		local called, notes = dispatched(cmdline)
		eq(called, "", label .. " runs nothing")
		eq(#notes, 1, label .. " gives one notice")
		local note = notes[1] or {}
		eq(note.level, vim.log.levels.ERROR, label .. " gives an error")
		eq(note.msg, want, label .. " says what was wrong")
	end
end)

H.case("Section 3: completion offers the subcommands for the first argument", function()
	local function offered(line)
		return table.concat(vim.fn.getcompletion(line, "cmdline"), " ")
	end
	eq(offered("MdKite "), table.concat(SUBCOMMANDS, " "), "the first argument offers every subcommand")
	eq(offered("MdKite st"), "start stop", "a typed prefix narrows them")
	eq(offered("silent MdKite t"), "toggle", "a modifier before the command counts for nothing")
	eq(offered("MdKite start "), "", "the second argument offers nothing")
end)

H.case("Section 4: each command from before the rename runs its subcommand, warned once", function()
	local names = vim.tbl_keys(FORWARDED)
	table.sort(names)
	for _, name in ipairs(names) do
		local sub = FORWARDED[name]
		local called, notes = dispatched(name)
		eq(called, sub, ":" .. name .. " runs " .. sub)
		eq(#notes, 1, ":" .. name .. " warns at its first use")
		local note = notes[1] or {}
		eq(note.level, vim.log.levels.WARN, ":" .. name .. " warns as a WARN")
		ok(
			(note.msg or ""):find(("use :MdKite %s instead"):format(sub), 1, true) ~= nil
				and (note.msg or ""):find("mdkite.nvim", 1, true) ~= nil,
			":" .. name .. " names :MdKite " .. sub .. " and the plugin: " .. tostring(note.msg)
		)
		called, notes = dispatched(name)
		eq(called, sub, ":" .. name .. " runs " .. sub .. " again")
		eq(#notes, 0, ":" .. name .. " warns once a session")
	end
end)

local tmpdir = H.tmpdir()
local md = vim.fs.joinpath(tmpdir, "doc.md")
H.write_file(md, "# toggled\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"

-- A port free a moment ago, so no row meets the developer's own preview on
-- the takeover default 8421.
local function free_port()
	local probe = vim.uv.new_tcp()
	probe:bind("127.0.0.1", 0)
	local port = probe:getsockname().port
	probe:close()
	return port
end

H.case("Section 5: toggle starts a stopped preview and stops a running one", function()
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0 })
	H.defer(mp.stop)
	vim.cmd("MdKite toggle")
	local inst = mp._server_instance
	ok(inst ~= nil, "toggle starts a stopped preview")
	local url = ("http://127.0.0.1:%d/"):format(inst and inst.port or 0)
	eq(H.http_get(url).status, 200, "the started preview answers")
	vim.cmd("MdKite toggle")
	eq(mp._server_instance, nil, "toggle stops a running preview")
	-- The close takes a turn of the loop before the port refuses (curl 7).
	vim.wait(200, function()
		return false
	end)
	eq(H.http_get(url).curl_exit, 7, "the stopped preview's port refuses connections")
	vim.cmd("MdKite toggle")
	ok(mp._server_instance ~= nil, "toggle starts it again")
end)

-- A second Neovim serving path as the takeover primary on port, in this
-- process's cache, until the enclosing case ends; it exits by itself after
-- 30 s if the kill is missed.
local function child_primary(path, port)
	local script = vim.fs.joinpath(H.tmpdir(), "primary.lua")
	H.write_file(
		script,
		([=[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("mdkite")
mp.setup({ open_browser = false, instance_mode = "takeover", port = %d })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
local inst = mp._server_instance
io.stdout:write(vim.json.encode({ port = inst and inst.port or 0 }) .. "\n")
io.stdout:flush()
vim.wait(30000, function() return false end)
]=]):format(server_dir, H.root, port, path)
	)
	local said = {}
	local proc = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, {
		stdout = function(_, data)
			if data then
				table.insert(said, data)
			end
		end,
	})
	H.defer(function()
		proc:kill(9)
		proc:wait(5000)
	end)
	if not H.wait_for(function()
		return table.concat(said):find("\n", 1, true) ~= nil
	end, 10000) then
		error("child_primary: the child said nothing in 10 s", 0)
	end
	local line = table.concat(said):match("({.-})")
	local decoded, got = pcall(vim.json.decode, line or "")
	if not decoded or type(got) ~= "table" or got.port ~= port then
		error("child_primary: the child did not serve port " .. port .. ": " .. table.concat(said), 0)
	end
end

H.case("Section 6: toggle stops a preview joined to another Neovim's", function()
	local port = free_port()
	child_primary(md, port)
	mp.setup({ open_browser = false, instance_mode = "takeover", port = port })
	H.defer(function()
		mp.stop()
		mp.setup({ instance_mode = "multi", port = 0 })
	end)
	vim.cmd("MdKite toggle")
	eq(mp._is_primary, false, "toggle joins the other Neovim's preview")
	vim.cmd("MdKite toggle")
	eq(mp._is_primary, nil, "toggle leaves the joined preview")
	eq(mp._server_instance, nil, "and starts no server of its own")
	eq(H.http_get(("http://127.0.0.1:%d/"):format(port)).status, 200, "the other Neovim's preview still answers")
end)

-- Each row previews a buffer of its own, its filetype set after the edit,
-- so no detection from the file's name stands in for it.
local function buffer_of(name, filetype, text)
	local path = vim.fs.joinpath(H.tmpdir(), name)
	H.write_file(path, text)
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	vim.bo.filetype = filetype
end

-- The text the running preview serves as its content, or nil when none runs.
local function served()
	local inst = mp._server_instance
	if not inst then
		return nil
	end
	local r = H.http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(inst.port, mp._token))
	return r.status == 200 and r.body or nil
end

-- The notices fn makes, recorded instead of shown; a raise goes on as one.
local function noticed(fn, ...)
	local notes, real_notify = {}, vim.notify
	vim.notify = function(msg, level)
		table.insert(notes, { msg = msg, level = level })
	end
	local ran, err = pcall(fn, ...)
	vim.notify = real_notify
	if not ran then
		error(tostring(err), 0)
	end
	return notes
end

-- Starts a preview of the current buffer; what it serves, and its notices.
local function started()
	local notes = noticed(mp.start)
	return served(), notes
end

-- A buffer not previewed whole is searched for the mermaid fence under the
-- cursor, which these buffers lack, so its start is that one error.
local function no_fence(notes)
	return #notes == 1 and notes[1].level == vim.log.levels.ERROR and notes[1].msg:find("```mermaid", 1, true) ~= nil
end

H.case("Section 7: a filetype with a markdown part previews the buffer whole", function()
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0 })
	H.defer(mp.stop)
	local body, notes
	-- The markdown part last, then first: a match on one end alone fails a row.
	for _, filetype in ipairs({ "rzk.markdown", "markdown.pandoc" }) do
		buffer_of("literate." .. filetype, filetype, "# literate\n\nprose and code\n")
		body, notes = started()
		eq(body, "# literate\n\nprose and code", filetype .. " previews the buffer whole with no filetypes set")
		eq(#notes, 0, filetype .. "'s start makes no notice")
		mp.stop()
	end
	-- A part that only begins or ends with the word is another filetype.
	for _, filetype in ipairs({ "rzk", "rzk.xmarkdown", "markdownx" }) do
		buffer_of("other." .. filetype, filetype, "# not markdown\n")
		body, notes = started()
		eq(body, nil, filetype .. " starts no preview of the buffer whole")
		ok(no_fence(notes), filetype .. " is searched for a mermaid fence: " .. tostring(notes[1] and notes[1].msg))
	end
end)

H.case("Section 8: filetypes previews more filetypes whole, beside markdown", function()
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0 })
	H.defer(function()
		mp.stop()
		mp.setup({ filetypes = {} })
	end)
	buffer_of("report.qmd", "quarto", "# quarto report\n")
	local body, notes = started()
	eq(body, nil, "quarto starts no preview of the buffer whole with no filetypes set")
	ok(no_fence(notes), "quarto is searched for a mermaid fence: " .. tostring(notes[1] and notes[1].msg))
	mp.setup({ filetypes = { "quarto" } })
	for _, case in ipairs({
		{ "report.qmd", "quarto", "# quarto report" },
		{ "plain.md", "markdown", "# plain markdown" },
		{ "literate.rzk", "rzk.markdown", "# literate" },
	}) do
		local name, filetype, text = case[1], case[2], case[3]
		buffer_of(name, filetype, text .. "\n")
		body, notes = started()
		eq(body, text, filetype .. ' previews the buffer whole with filetypes = { "quarto" }')
		eq(#notes, 0, filetype .. "'s start makes no notice")
		mp.stop()
	end
	-- A later setup's list replaces the earlier one, never adds to it.
	mp.setup({ filetypes = { "rmd" } })
	buffer_of("report.qmd", "quarto", "# quarto report\n")
	body, notes = started()
	eq(body, nil, 'quarto starts no preview of the buffer whole once filetypes = { "rmd" }')
	ok(no_fence(notes), "quarto is searched for a mermaid fence again: " .. tostring(notes[1] and notes[1].msg))
end)

H.case("Section 9: setup refuses a filetypes that is not a list of filetype names", function()
	local want = 'mdkite: filetypes takes a list of filetype names, such as { "quarto" }; setup changed nothing'
	mp.setup({ filetypes = { "quarto" }, debounce_ms = 300 })
	H.defer(function()
		mp.setup({ filetypes = {} })
	end)
	local list, set = mp.config.filetypes, mp._filetype_set
	for _, case in ipairs({
		-- ipairs raises on a string, so setup would end in a raw Lua error.
		{ "a string", "quarto" },
		{ "a table that is no list", { kind = "quarto" } },
		{ "a list with a number in it", { "quarto", 3 } },
		-- No buffer has the empty filetype name, but one with none would match it.
		{ "a list with an empty name in it", { "" } },
	}) do
		local label, value = case[1], case[2]
		local notes = noticed(mp.setup, { filetypes = value, debounce_ms = 1 })
		eq(#notes, 1, label .. " gives one notice")
		local note = notes[1] or {}
		eq(note.level, vim.log.levels.ERROR, label .. " gives an error")
		eq(note.msg, want, label .. " says what filetypes takes")
		eq(mp.config.debounce_ms, 300, label .. " leaves the rest of the call unapplied")
		ok(
			rawequal(mp.config.filetypes, list) and rawequal(mp._filetype_set, set),
			label .. " leaves filetypes and the set setup built as they were"
		)
	end
end)

H.case("Section 10: setup builds the filetype set once, and a refresh reads that set", function()
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0, filetypes = { "quarto" } })
	H.defer(function()
		mp.stop()
		mp.setup({ filetypes = {} })
	end)
	buffer_of("first.md", "markdown", "# first\n")
	eq((started()), "# first", "a markdown buffer starts the preview")
	local set = mp._filetype_set
	-- The config keeps the list setup was given, so a refresh that built the
	-- set again would read a name added to it afterwards.
	table.insert(mp.config.filetypes, "late")
	buffer_of("late.txt", "late", "# late\n")
	mp.refresh()
	eq(served(), "# first", "a refresh does not read a filetype added to the config after setup")
	buffer_of("report.qmd", "quarto", "# quarto report\n")
	mp.refresh()
	eq(served(), "# quarto report", "a refresh writes a buffer of a filetype setup was given")
	ok(rawequal(mp._filetype_set, set), "and the set it read is the one setup built")
end)

H.finish()
