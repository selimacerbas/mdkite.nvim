-- tests/page_title_test.lua
-- The page_title option names the browser tab after the buffer: its
-- template fills ${name} and ${path} into a page_title sidecar beside
-- content.md, which the page reads on each sync. The sidecar names the
-- buffer's path, so it stays behind the token, and a file name with a %
-- in it fills in as written, where a gsub replacement string raised.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/page_title_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local dir = H.tmpdir()
local md = dir .. "/a%20b.md"
H.write_file(md, "# title\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"
local fullpath = vim.api.nvim_buf_get_name(0)

local mp = require("mdkite")
-- A section that raises leaves its server to this.
H.defer(function()
	if mp._server_instance then
		mp.stop()
	end
end)

-- Starts a multi-mode preview under opts and returns the sidecar's path
-- and the served root's URL.
local function start(opts)
	mp.setup(vim.tbl_extend("force", { open_browser = false, instance_mode = "multi" }, opts))
	mp.start()
	return vim.fs.joinpath(mp._workspace_dir, "page_title"), ("http://127.0.0.1:%d"):format(mp._server_instance.port)
end

local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

H.case("Section 1: the default template is the file name, and the sidecar is gated", function()
	local sidecar, base = start({})
	H.eq(read(sidecar), "a%20b.md", "the sidecar beside content.md holds the file name, % and all")
	H.eq(H.http_get(base .. "/page_title").status, 401, "the page_title sidecar without the token is 401")
	H.eq(H.http_get(base .. "/page_title?t=wrong").status, 401, "the page_title sidecar with a wrong token is 401")
	local r = H.http_get(base .. "/page_title?t=" .. mp._token)
	H.eq(r.status, 200, "the page_title sidecar with the token is 200")
	H.eq(r.body, "a%20b.md", "and its body is the title")
	mp.stop()
end)

H.case("Section 2: a template fills ${name} and ${path}", function()
	local sidecar = start({ page_title = "${name} | ${path} | ${name}" })
	H.eq(read(sidecar), "a%20b.md | " .. fullpath .. " | a%20b.md", "each placeholder fills in, every time it appears")
	mp.stop()
end)

H.case("Section 3: an empty or false template writes no title", function()
	for _, off in ipairs({ "", false }) do
		local sidecar, base = start({ page_title = off })
		H.eq(
			read(sidecar),
			nil,
			("page_title = %s leaves no sidecar, the last start's removed"):format(vim.inspect(off))
		)
		H.eq(H.http_get(base .. "/page_title?t=" .. mp._token).status, 404, "and the route answers 404")
		mp.stop()
		-- The next pass must find a sidecar to remove.
		start({ page_title = "${name}" })
		mp.stop()
	end
end)

H.finish()
