--!strict
-- Host half for tern-colab: defines the `tern-colab.sessions` block for
-- inspecting Google Colab sessions, compute units, and launching SSH panes.
--
-- Keys:
--   ↑/↓ or j/k : move selection
--   Home/End   : jump to first/last
--   Enter / o  : open SSH pane for selected session
--   n          : provision a new Colab runtime & open SSH
--   e          : provision an ephemeral runtime & open SSH; stops when its pane closes
--   x / Backspace : stop selected session
--   r          : refresh sessions & compute units
--   c          : copy ~/.ssh/config ProxyCommand snippet

local colab = require("./lib/colab")
local ui = tern.ui

local POLL_MS = 60 * 1000
local CMD_TIMEOUT_MS = 25 * 1000
local LIST_ID = "main.sessions."
local DOCS_URL = "https://github.com/googlecolab/google-colab-cli"

type Problem = {
	kind: string,
	title: string,
	detail: string,
}

type State = {
	cx: BlockCx,
	bin: string?,
	sessions: { colab.SessionInfo }?,
	usage: colab.UsageInfo?,
	cursor: string?,
	loading: boolean,
	action_msg: string?,
	fetched: number?,
	problem: Problem?,
	timer: TimerHandle?,
	stopped: boolean,
}

local running: { [number]: State } = {}

local function save_snapshot(state: State)
	local payload: { [string]: any } = {
		bin = state.bin,
		usage = state.usage,
		sessions = state.sessions,
		fetched = state.fetched,
	}
	pcall(tern.kv.set, "snapshot", payload)
end

local function load_snapshot(): (string?, { colab.SessionInfo }?, colab.UsageInfo?, number?)
	local ok, snap = pcall(tern.kv.get, "snapshot")
	if not ok or type(snap) ~= "table" then
		return nil, nil, nil, nil
	end

	local bin: string? = if type(snap.bin) == "string" and snap.bin ~= "" then snap.bin else nil
	local fetched: number? = if type(snap.fetched) == "number" then snap.fetched else nil

	local usage: colab.UsageInfo? = nil
	if type(snap.usage) == "table"
		and type(snap.usage.balance) == "string"
		and type(snap.usage.rate) == "string"
		and type(snap.usage.assignments) == "string"
	then
		usage = {
			balance = snap.usage.balance,
			rate = snap.usage.rate,
			assignments = snap.usage.assignments,
		}
	end

	local sessions: { colab.SessionInfo }? = nil
	if type(snap.sessions) == "table" then
		local list: { colab.SessionInfo } = {}
		for _, item in snap.sessions :: { any } do
			if type(item) == "table" and type(item.key) == "string" and type(item.name) == "string" then
				table.insert(list, {
					key = item.key,
					name = item.name,
					endpoint = if type(item.endpoint) == "string" then item.endpoint else "",
					hardware = if type(item.hardware) == "string" then item.hardware else "",
					shape = if type(item.shape) == "string" then item.shape else "",
					variant = if type(item.variant) == "string" then item.variant else "",
					orphaned = item.orphaned == true,
				})
			end
		end
		sessions = list
	end

	return bin, sessions, usage, fetched
end

local function is_alive(state: State): boolean
	if state.stopped or running[state.cx.pane] ~= state then
		return false
	end
	for _, pane in tern.pane.list() do
		if pane.pane == state.cx.pane then
			return true
		end
	end
	return false
end

local function retire(state: State)
	state.stopped = true
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
end

local function selected_session(state: State): colab.SessionInfo?
	if not state.sessions or #state.sessions == 0 then
		return nil
	end
	if state.cursor then
		for _, s in state.sessions do
			if s.key == state.cursor then
				return s
			end
		end
	end
	return state.sessions[1]
end

local function index_of(state: State): number
	if not state.sessions or #state.sessions == 0 then
		return 1
	end
	if state.cursor then
		for i, s in state.sessions do
			if s.key == state.cursor then
				return i
			end
		end
	end
	return 1
end

local function move_cursor(state: State, to: number)
	if not state.sessions or #state.sessions == 0 then
		state.cursor = nil
		return
	end
	local idx = math.clamp(to, 1, #state.sessions)
	state.cursor = state.sessions[idx].key
end

local function run_colab(bin: string, args: { string }, cb: (ProcessResult) -> ())
	local argv = { bin }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok = pcall(function()
		tern.process.run(argv, {
			timeout_ms = CMD_TIMEOUT_MS,
			env = {
				NO_COLOR = "1",
				CLICOLOR = "0",
			},
		}, function(result: ProcessResult)
			cb(result)
		end)
	end)
	if not ok then
		cb({
			status = -1,
			stdout = "",
			stderr = "Failed to spawn " .. bin,
			timed_out = false,
		})
	end
end

local function safe_exists(path: string): boolean
	local ok, exists = pcall(tern.fs.exists, path)
	return ok and exists == true
end

local function verify_help(cand: string, cb: (boolean) -> ())
	local spawned = pcall(function()
		tern.process.run({ cand, "--help" }, {
			timeout_ms = 5000,
			env = {
				NO_COLOR = "1",
				CLICOLOR = "0",
				TERM = "dumb",
			},
		}, function(res: ProcessResult)
			cb(res.status == 0)
		end)
	end)
	if not spawned then
		cb(false)
	end
end

local function probe_shell_fallback(cb: (string?) -> ())
	local env_shell = tern.getenv("SHELL")
	local shell: string = if env_shell and env_shell ~= "" then env_shell else "/bin/zsh"
	local spawned = pcall(function()
		tern.process.run({ shell, "-lc", "command -v colab" }, {
			timeout_ms = 5000,
			env = { NO_COLOR = "1" },
		}, function(res: ProcessResult)
			if res.status ~= 0 then
				cb(nil)
				return
			end
			local resolved = colab.first_line(res.stdout)
			if resolved == "" or (string.sub(resolved, 1, 1) == "/" and not safe_exists(resolved)) then
				cb(nil)
				return
			end
			verify_help(resolved, function(ok: boolean)
				cb(if ok then resolved else nil)
			end)
		end)
	end)
	if not spawned then
		cb(nil)
	end
end

local function probe_bin(cb: (string?) -> ())
	local candidates = colab.candidate_bins(tern.getenv, tern.plugin.dir)
	local ok_kv, cached = pcall(tern.kv.get, "resolved_bin")
	if ok_kv and type(cached) == "string" and cached ~= "" then
		local override = tern.getenv("TERN_COLAB_BIN")
		local insert_at = if override and override ~= "" then 2 else 1
		if not table.find(candidates, cached) then
			table.insert(candidates, insert_at, cached)
		end
	end

	local function finish(found: string?)
		if found then
			pcall(tern.kv.set, "resolved_bin", found)
		end
		cb(found)
	end

	local function try_next(i: number)
		if i > #candidates then
			probe_shell_fallback(finish)
			return
		end
		local cand = candidates[i]
		if string.sub(cand, 1, 1) == "/" and not safe_exists(cand) then
			try_next(i + 1)
			return
		end
		verify_help(cand, function(ok: boolean)
			if ok then
				finish(cand)
			else
				try_next(i + 1)
			end
		end)
	end
	try_next(1)
end

local function make_problem(kind: string, detail: string): Problem
	if kind == "missing" then
		return {
			kind = "missing",
			title = "google-colab-cli (`colab`) not found",
			detail = "Install with: uv tool install google-colab-cli (or set TERN_COLAB_BIN)",
		}
	elseif kind == "auth" then
		return {
			kind = "auth",
			title = "Google Colab authentication required",
			detail = detail .. " — Run `colab usage` or `colab new` in a terminal once to finish OAuth sign-in.",
		}
	elseif kind == "key" then
		return {
			kind = "key",
			title = "Ed25519/ECDSA SSH key missing",
			detail = detail .. " — Run `ssh-keygen -t ed25519` (Colab rejects id_rsa).",
		}
	end
	return {
		kind = kind,
		title = "Could not query Google Colab",
		detail = detail,
	}
end

local function refresh(state: State)
	if state.loading or not is_alive(state) then
		return
	end
	state.loading = true
	state.cx:render()

	local function fetch_with_bin(bin: string)
		local pending = 2
		local sess_res: ProcessResult? = nil
		local usage_res: ProcessResult? = nil

		local function finish()
			pending -= 1
			if pending > 0 then
				return
			end
			if not is_alive(state) then
				return
			end
			state.loading = false

			if sess_res and sess_res.status == 0 then
				local parsed = colab.parse_sessions(sess_res.stdout)
				state.sessions = parsed
				state.problem = nil
				state.fetched = os.time()
				if #parsed == 0 then
					state.cursor = nil
				elseif not selected_session(state) then
					state.cursor = parsed[1].key
				end
			elseif sess_res then
				local kind, detail = colab.classify_error(sess_res.status, sess_res.stderr, sess_res.stdout)
				state.problem = make_problem(kind, detail)
			end

			if usage_res and usage_res.status == 0 then
				local parsed_usage = colab.parse_usage(usage_res.stdout)
				if parsed_usage then
					state.usage = parsed_usage
				end
			end

			if state.sessions or state.usage then
				save_snapshot(state)
			end

			state.cx:render()
		end

		run_colab(bin, { "sessions" }, function(res: ProcessResult)
			sess_res = res
			finish()
		end)

		run_colab(bin, { "usage" }, function(res: ProcessResult)
			usage_res = res
			finish()
		end)
	end

	if state.bin then
		fetch_with_bin(state.bin)
	else
		probe_bin(function(found: string?)
			if not is_alive(state) then
				return
			end
			if not found then
				state.loading = false
				state.problem = make_problem("missing", "colab not on PATH or ~/.local/bin")
				state.cx:render()
				return
			end
			state.bin = found
			fetch_with_bin(found)
		end)
	end
end

local function schedule_poll(state: State)
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	state.timer = tern.timer(POLL_MS, function()
		state.timer = nil
		if not is_alive(state) then
			retire(state)
			return
		end
		refresh(state)
		schedule_poll(state)
	end)
end

local function stop_selected(state: State, cx: BlockCx)
	local s = selected_session(state)
	if not s then
		cx:toast("info", "No session selected", nil)
		return
	end
	if s.orphaned then
		cx:toast("error", "Cannot stop orphaned `[?]` session by name", "Stop it from Colab web or match its local name.")
		return
	end
	local bin = state.bin
	if not bin then
		cx:toast("error", "colab CLI not found", nil)
		return
	end
	state.action_msg = "Stopping " .. s.name .. "…"
	cx:render()
	run_colab(bin, { "stop", "-s", s.name }, function(res: ProcessResult)
		if not is_alive(state) then
			return
		end
		state.action_msg = nil
		if res.status == 0 then
			cx:toast("success", "Stopped Colab session", s.name)
			refresh(state)
		else
			local _, detail = colab.classify_error(res.status, res.stderr, res.stdout)
			cx:toast("error", "Failed to stop " .. s.name, detail)
			cx:render()
		end
	end)
end

local function connect_selected(state: State, cx: BlockCx)
	local s = selected_session(state)
	if not s then
		cx:open("colab-ssh://new")
		return
	end
	if s.orphaned then
		cx:toast(
			"error",
			"Session has no local name (`?`)",
			"Provision a named session with `n` to manage & SSH directly."
		)
		return
	end
	cx:open("colab-ssh://connect?session=" .. colab.url_encode(s.name))
end

local function list_lines(state: State, cx: BlockCx): number
	local reserved = 7
	if state.usage then
		reserved += 3
	end
	if state.problem then
		reserved += 4
	end
	return math.max(4, cx.rows - reserved)
end

local function toolbar_view(state: State): Node
	local sel = selected_session(state)
	local can_ssh: boolean | string = if sel and not sel.orphaned then false else "Select a named session"
	local can_stop: boolean | string = if sel and not sel.orphaned and not state.action_msg then false else "Select a named session"

	return ui.row({
		ui.button("New & SSH", {
			key = "btn_new",
			icon = "plus",
			variant = "primary",
			keys = { "n" },
			actions = { click = "new" },
		}),
		ui.button("Ephemeral", {
			key = "btn_new_rm",
			icon = "bolt",
			keys = { "e" },
			title = "Provision ephemeral runtime (stops when its pane closes)",
			actions = { click = "new_rm" },
		}),
		ui.button("SSH", {
			key = "btn_ssh",
			icon = "terminal",
			keys = { "enter" },
			disabled = can_ssh,
			actions = { click = "connect" },
		}),
		ui.button("Stop", {
			key = "btn_stop",
			icon = "stop",
			variant = "danger",
			keys = { "x" },
			disabled = can_stop,
			actions = { click = "stop" },
		}),
		ui.button("Refresh", {
			key = "btn_refresh",
			icon = "repeat",
			keys = { "r" },
			busy = state.loading,
			actions = { click = "refresh" },
		}),
		ui.button("SSH Config", {
			key = "btn_cfg",
			icon = "copy",
			variant = "quiet",
			keys = { "c" },
			actions = { click = "ssh_config" },
		}),
	})
end

local function problem_view(problem: Problem): Node
	local actions = {
		ui.button("Retry", {
			key = "retry",
			icon = "repeat",
			variant = "primary",
			actions = { click = "retry" },
		}),
	}
	if problem.kind == "missing" then
		table.insert(actions, ui.button("CLI Docs", {
			key = "docs",
			icon = "open",
			actions = { click = "docs" },
		}))
	end
	return ui.card({ ui.span(problem.title, "strong") }, {
		ui.text(problem.detail),
		ui.row(actions),
	}, {
		key = "problem",
		icon = "warn",
		tone = "warning",
	})
end

local function sessions_list_view(state: State, cx: BlockCx): Node
	local sessions: { colab.SessionInfo } = state.sessions or {}
	local items: { Item } = {}
	for _, s in sessions do
		local label: { Span | string } = {
			ui.span(s.name, "strong"),
			ui.span("  " .. s.endpoint, "mono muted"),
		}
		if s.orphaned then
			table.insert(label, ui.span("  (untracked)", "warning"))
		end
		table.insert(items, {
			label = label,
			detail = s.variant .. " · " .. s.shape,
			value = ui.span(s.hardware, if s.hardware == "CPU" then "muted" else "strong"),
			icon = colab.hardware_icon(s.hardware, s.variant),
			tone = if s.orphaned then "warning" elseif s.hardware ~= "CPU" then "info" else "muted",
		})
	end

	local list = ui.list(items)
	if list.c then
		for i, child in list.c do
			local cp: { [string]: any } = child.p or {}
			cp.key = sessions[i].key
			child.p = cp
		end
	end

	local sel = selected_session(state)
	local lp: { [string]: any } = list.p or {}
	lp.key = "sessions"
	lp.selected = if sel then LIST_ID .. sel.key else nil
	lp.empty = { ui.span("No active Colab runtimes. Press ", "muted"), ui.span("n", "key"), ui.span(" to provision & SSH.", "muted") }
	lp.max = { lines = list_lines(state, cx) }
	list.p = lp
	return list
end

local function stats_view(usage: colab.UsageInfo): Node
	return ui.stats({
		{ label = "Compute Units", value = usage.balance, tone = "accent" },
		{ label = "Burn Rate", value = usage.rate, tone = "info" },
		{ label = "Active VMs", value = usage.assignments },
	})
end

local function dock_view(state: State): Node
	local status: { Span | string } = {}
	if state.action_msg then
		table.insert(status, ui.span(state.action_msg, "accent"))
	elseif state.loading then
		table.insert(status, ui.span("Syncing with Colab…", "muted"))
	elseif state.fetched then
		local count = if state.sessions then #state.sessions else 0
		table.insert(status, ui.span(tostring(count) .. " active", "strong"))
		table.insert(status, ui.span("  updated " .. tostring(os.date("%H:%M:%S", state.fetched)), "muted"))
	end
	table.insert(
		status,
		ui.span("    ↑↓ move  ⏎ ssh  n new  e tmp  x stop  r sync  c cfg  q hide", "dim")
	)
	return ui.col({ ui.text(status) })
end

local def: BlockDef<State> = {
	font = "sans",

	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local prev = running[cx.pane]
		if prev then
			retire(prev)
		end
		local saved_cursor: string? = nil
		if type(saved) == "table" and type(saved.cursor) == "string" then
			saved_cursor = saved.cursor
		end
		local snap_bin, snap_sessions, snap_usage, snap_fetched = load_snapshot()
		local init_cursor = saved_cursor
		if not init_cursor and snap_sessions and #snap_sessions > 0 then
			init_cursor = snap_sessions[1].key
		end
		local state: State = {
			cx = cx,
			bin = snap_bin,
			sessions = snap_sessions,
			usage = snap_usage,
			cursor = init_cursor,
			loading = false,
			action_msg = nil,
			fetched = snap_fetched,
			problem = nil,
			timer = nil,
			stopped = false,
		}
		running[cx.pane] = state
		refresh(state)
		schedule_poll(state)
		return state
	end,

	title = function(state: State): string?
		if state.usage then
			return "Colab (" .. state.usage.balance .. " CU)"
		elseif state.sessions then
			return "Colab (" .. tostring(#state.sessions) .. ")"
		end
		return "Colab Sessions"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local nodes: { Node } = {}
		if state.usage then
			table.insert(nodes, stats_view(state.usage))
		end
		table.insert(nodes, toolbar_view(state))

		if state.sessions then
			if state.problem then
				table.insert(nodes, problem_view(state.problem))
			end
			table.insert(nodes, sessions_list_view(state, cx))
		elseif state.problem then
			table.insert(nodes, problem_view(state.problem))
		else
			table.insert(nodes, ui.progress(nil, "Querying Google Colab sessions & quota…"))
		end

		return {
			main = ui.col(nodes),
			dock = dock_view(state),
		}
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		local idx = index_of(state)
		if key.name == "up" or k == "k" then
			move_cursor(state, idx - 1)
		elseif key.name == "down" or k == "j" then
			move_cursor(state, idx + 1)
		elseif key.name == "home" or k == "g" then
			move_cursor(state, 1)
		elseif key.name == "end" or k == "G" then
			local n = if state.sessions then #state.sessions else 1
			move_cursor(state, n)
		elseif key.name == "enter" or k == "o" then
			connect_selected(state, cx)
		elseif k == "n" then
			cx:open("colab-ssh://new")
		elseif k == "e" then
			cx:open("colab-ssh://new-rm")
		elseif k == "c" then
			cx:open("colab-ssh://ssh-config")
		elseif k == "x" or key.name == "backspace" or key.name == "delete" then
			stop_selected(state, cx)
		elseif k == "r" then
			refresh(state)
		elseif key.name == "escape" or k == "q" then
			cx:open("colab-ssh://hide")
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" then
			local act = ev.act
			if act == "refresh" or act == "retry" then
				refresh(state)
			elseif act == "new" then
				cx:open("colab-ssh://new")
			elseif act == "new_rm" then
				cx:open("colab-ssh://new-rm")
			elseif act == "connect" then
				connect_selected(state, cx)
			elseif act == "stop" then
				stop_selected(state, cx)
			elseif act == "ssh_config" then
				cx:open("colab-ssh://ssh-config")
			elseif act == "docs" then
				cx:open(DOCS_URL)
			end
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			if string.sub(ev.item, 1, #LIST_ID) == LIST_ID then
				state.cursor = string.sub(ev.item, #LIST_ID + 1)
				if ev.ev == "activate" then
					connect_selected(state, cx)
				end
			end
		end
	end,

	save = function(state: State): any
		return { cursor = state.cursor }
	end,
}

tern.block.define("sessions", def)

tern.on("unload", function()
	for _, state in running do
		retire(state)
	end
end)
