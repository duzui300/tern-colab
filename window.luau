--!strict

local colab = require("./lib/colab")

local BLOCK_ID = "tern-colab.sessions"
local glimpse_panes: { [number]: boolean } = {}

tern.on("pane_closed", function(ev: PaneEvent, _cx: WindowCx)
	glimpse_panes[ev.pane] = nil
end)

type SessionCallback = (sessions: { colab.SessionInfo }?, err_kind: string?, err_detail: string?) -> ()

local function is_desktop(): boolean
	return tern.runtime.os ~= "ios"
end

local function desktop_available(_cx: WindowCx): boolean
	return is_desktop()
end

local function safe_exists(path: string): boolean
	local ok, exists = pcall(tern.fs.exists, path)
	return ok and exists == true
end

local function resolve_bin(): string
	local override = tern.getenv("TERN_COLAB_BIN")
	if override and override ~= "" then
		if string.sub(override, 1, 1) ~= "/" or safe_exists(override) then
			return override
		end
	end

	local ok_kv, cached = pcall(tern.kv.get, "resolved_bin")
	if ok_kv and type(cached) == "string" and cached ~= "" then
		if string.sub(cached, 1, 1) ~= "/" or safe_exists(cached) then
			return cached
		end
	end

	local candidates = colab.candidate_bins(tern.getenv, tern.plugin.dir)
	for _, candidate in ipairs(candidates) do
		if string.sub(candidate, 1, 1) == "/" and safe_exists(candidate) then
			return candidate
		end
	end
	return "colab"
end

local function generate_session_name(preset_id: string): string
	local secs = math.floor(tern.now() / 1000)
	local suffix = string.format("%04d", math.abs(secs) % 10000)
	return "colab-" .. preset_id .. "-" .. suffix
end

local function toast_cli_error(cx: WindowCx, title: string, kind: string, detail: string)
	if kind == "auth" then
		cx:toast("error", title .. " (Colab auth required)", "Run `colab usage` once in a terminal to sign in.")
	elseif kind == "key" then
		cx:toast("error", title .. " (Ed25519/ECDSA SSH key required)", "Create one with: ssh-keygen -t ed25519")
	else
		local msg = if detail ~= "" then detail else "colab command failed"
		cx:toast("error", title, msg)
	end
end

local function first_leaf_pane(node: TabTree, exclude_pane: number?): number?
	if node.pane ~= nil then
		if node.pane ~= exclude_pane then
			return node.pane
		end
		return nil
	end
	if node[1] ~= nil then
		local left = first_leaf_pane(node[1], exclude_pane)
		if left ~= nil then
			return left
		end
	end
	if node[2] ~= nil then
		return first_leaf_pane(node[2], exclude_pane)
	end
	return nil
end

local function is_pane_in_tree(node: TabTree, pane_id: number): boolean
	if node.pane ~= nil then
		return node.pane == pane_id
	end
	if node[1] ~= nil and is_pane_in_tree(node[1], pane_id) then
		return true
	end
	if node[2] ~= nil and is_pane_in_tree(node[2], pane_id) then
		return true
	end
	return false
end

local function is_glimpse_pane(cx: WindowCx, p: PaneInfo): boolean
	if not glimpse_panes[p.pane] then
		return false
	end
	if p.tab ~= nil then
		local layout = cx.session:layout(p.tab)
		if layout ~= nil and is_pane_in_tree(layout.root, p.pane) then
			glimpse_panes[p.pane] = nil
			return false
		end
	end
	return not p.floating and not p.parked
end

local function find_tiled_anchor(cx: WindowCx, exclude_pane: number?): number?
	local focused = cx.session:focused()
	local target_tab: number? = nil
	if focused ~= nil then
		local info = cx.session:pane(focused)
		if info ~= nil then
			target_tab = info.tab
			if not info.floating and not info.parked and not is_glimpse_pane(cx, info) and focused ~= exclude_pane then
				return focused
			end
			if info.tab ~= nil then
				local layout = cx.session:layout(info.tab)
				if layout ~= nil then
					if info.floating then
						for _, fl in ipairs(layout.floats) do
							if fl.pane == focused and fl.over ~= exclude_pane then
								return fl.over
							end
						end
					end
					local leaf = first_leaf_pane(layout.root, exclude_pane)
					if leaf ~= nil then
						return leaf
					end
				end
			end
		end
	end

	for _, p in ipairs(cx.session:panes()) do
		if
			not p.floating
			and not p.parked
			and not is_glimpse_pane(cx, p)
			and p.tab ~= nil
			and (target_tab == nil or p.tab == target_tab)
			and p.pane ~= exclude_pane
			and p.block ~= BLOCK_ID
		then
			return p.pane
		end
	end
	return nil
end

local function find_sessions_pane(cx: WindowCx): PaneInfo?
	for _, pane in ipairs(cx.session:panes()) do
		if pane.block == BLOCK_ID then
			return pane
		end
	end
	return nil
end

local function close_popup_panel(cx: WindowCx)
	local existing = find_sessions_pane(cx)
	if existing == nil then
		return
	end
	if is_glimpse_pane(cx, existing) then
		glimpse_panes[existing.pane] = nil
		cx.layout:close(existing.pane)
	elseif existing.floating then
		cx.layout:park(existing.pane)
	end
end

local function open_ssh_pane(cx: WindowCx, cmd: string)
	local target = find_tiled_anchor(cx, nil)
	close_popup_panel(cx)
	if target ~= nil then
		local created = cx.layout:split(target, "right", { command = cmd })
		if created ~= nil then
			cx.layout:focus(created)
			return
		end
	end
	cx.layout:new_tab({ command = cmd })
end

local function launch_ssh(cx: WindowCx, opts: colab.SshLaunchOpts, subtitle: string)
	local bin = resolve_bin()
	local cmd = colab.build_ssh_command(bin, opts)
	-- Tern runs pane commands through the login shell. PowerShell needs the call
	-- operator before a quoted executable.
	if tern.runtime.os == "windows" then
		cmd = "& " .. cmd
	end
	open_ssh_pane(cx, cmd)
	cx:toast("info", "Opening Colab SSH pane", subtitle)
end

local function run_colab(
	subargs: { string },
	timeout_ms: number,
	cb: (res: ProcessResult?, err_kind: string?, err_detail: string?) -> ()
)
	local argv: { string } = { resolve_bin() }
	for _, arg in ipairs(subargs) do
		table.insert(argv, arg)
	end
	tern.process.run(argv, { timeout_ms = timeout_ms }):next(
		function(res: ProcessResult?, err: string?, _cx: WindowCx?)
			if err ~= nil then
				cb(nil, "failed", err)
				return
			end
			if res == nil then
				cb(nil, "failed", "colab returned no result")
				return
			end
			if res.status ~= 0 then
				local kind, detail = colab.classify_error(res.status, res.stderr, res.stdout)
				cb(nil, kind, detail)
				return
			end
			cb(res, nil, nil)
		end
	)
end

local function fetch_sessions(cb: SessionCallback)
	run_colab({ "sessions" }, 12000, function(res: ProcessResult?, err_kind: string?, err_detail: string?)
		if err_kind ~= nil or res == nil then
			cb(nil, err_kind or "failed", err_detail or "")
			return
		end
		cb(colab.parse_sessions(res.stdout), nil, nil)
	end)
end

local function build_preset_items(label_prefix: string): { PickItem }
	local items: { PickItem } = {}
	for _, preset in ipairs(colab.PRESETS) do
		table.insert(items, {
			id = "preset:" .. preset.id,
			label = label_prefix .. preset.label,
			detail = preset.detail,
			icon = preset.icon,
		})
	end
	return items
end

local function prompt_safe_name(
	cx: WindowCx,
	title: string,
	placeholder: string,
	default_name: () -> string,
	on_valid: (WindowCx, string) -> ()
)
	cx:prompt({
		title = title,
		placeholder = placeholder,
	}):next(function(raw: string?, _err: string?, next_cx: WindowCx?)
		if raw == nil then
			return
		end
		local active_cx = next_cx or cx
		local trimmed = colab.trim(raw)
		local resolved: string?
		if trimmed == "" then
			resolved = default_name()
		else
			resolved = colab.sanitize_name(trimmed)
		end
		if resolved == nil then
			active_cx:toast("error", "Invalid name", "Use letters, digits, ., _, or - only.")
			return
		end
		on_valid(active_cx, resolved)
	end)
end

local function prompt_and_launch_preset(cx: WindowCx, preset: colab.Preset, ephemeral: boolean)
	local title = if ephemeral
		then "Ephemeral Colab SSH (--rm): " .. preset.label
		else "Provision Colab SSH: " .. preset.label
	prompt_safe_name(
		cx,
		title,
		"Session name (leave blank to auto-generate)",
		function(): string
			return generate_session_name(preset.id)
		end,
		function(next_cx: WindowCx, session_name: string)
			launch_ssh(next_cx, {
				session = session_name,
				gpu = preset.gpu,
				tpu = preset.tpu,
				high_mem = preset.high_mem,
				rm = ephemeral,
			}, session_name .. " · " .. preset.label)
		end
	)
end

local function start_preset_picker(
	cx: WindowCx,
	title: string,
	label_prefix: string,
	on_select: (WindowCx, colab.Preset) -> ()
)
	cx:pick({
		title = title,
		items = build_preset_items(label_prefix),
	}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
		if item == nil then
			return
		end
		local active_cx = next_cx or cx
		local preset_id = string.gsub(item.id, "^preset:", "")
		local preset = colab.find_preset(preset_id)
		if preset == nil then
			active_cx:toast("error", "Unknown Colab preset", item.id)
			return
		end
		on_select(active_cx, preset)
	end)
end

local function start_connect_flow(cx: WindowCx)
	fetch_sessions(function(sessions: { colab.SessionInfo }?, err_kind: string?, err_detail: string?)
		if err_kind == "auth" then
			toast_cli_error(cx, "Unable to list Colab sessions", "auth", err_detail or "")
			return
		end

		local items: { PickItem } = {}
		if sessions ~= nil then
			for _, s in ipairs(sessions) do
				if not s.orphaned and s.name ~= "?" then
					local desc = s.hardware
					if s.shape ~= "" then
						desc = desc .. " (" .. s.shape .. ")"
					end
					if s.endpoint ~= "" then
						desc = desc .. " · " .. s.endpoint
					end
					table.insert(items, {
						id = "session:" .. s.name,
						label = "Attach: " .. s.name,
						detail = desc,
						icon = colab.hardware_icon(s.hardware, s.variant),
					})
				end
			end
		end

		for _, preset_item in ipairs(build_preset_items("New: ")) do
			table.insert(items, preset_item)
		end

		cx:pick({
			title = "Colab SSH: Attach or Provision",
			items = items,
		}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local active_cx = next_cx or cx
			if string.sub(item.id, 1, 8) == "session:" then
				local raw_name = string.sub(item.id, 9)
				local safe_name = colab.sanitize_name(raw_name)
				if safe_name == nil then
					active_cx:toast("error", "Invalid session name", raw_name)
					return
				end
				launch_ssh(active_cx, { session = safe_name }, safe_name)
				return
			end

			local preset_id = string.gsub(item.id, "^preset:", "")
			local preset = colab.find_preset(preset_id)
			if preset ~= nil then
				prompt_and_launch_preset(active_cx, preset, false)
			end
		end)
	end)
end

local function start_ephemeral_flow(cx: WindowCx)
	start_preset_picker(cx, "Ephemeral Colab SSH (--rm)", "", function(next_cx: WindowCx, preset: colab.Preset)
		prompt_and_launch_preset(next_cx, preset, true)
	end)
end

local function start_ssh_config_flow(cx: WindowCx)
	start_preset_picker(
		cx,
		"Copy ~/.ssh/config ProxyCommand Entry",
		"",
		function(next_cx: WindowCx, preset: colab.Preset)
			local default_alias = "colab-" .. preset.id
			prompt_safe_name(
				next_cx,
				"SSH Host alias for " .. preset.label,
				default_alias,
				function(): string
					return default_alias
				end,
				function(done_cx: WindowCx, alias: string)
					local entry = colab.build_ssh_config_entry(resolve_bin(), preset, alias)
					done_cx:copy(entry)
					done_cx:toast(
						"success",
						"Copied SSH config for " .. alias,
						"Paste into ~/.ssh/config, then use `tern ssh " .. alias .. "`."
					)
				end
			)
		end
	)
end

local function stop_session_flow(cx: WindowCx)
	fetch_sessions(function(sessions: { colab.SessionInfo }?, err_kind: string?, err_detail: string?)
		if err_kind ~= nil then
			toast_cli_error(cx, "Failed to list Colab sessions", err_kind, err_detail or "")
			return
		end
		local items: { PickItem } = {}
		if sessions ~= nil then
			for _, s in ipairs(sessions) do
				if not s.orphaned and s.name ~= "?" then
					table.insert(items, {
						id = s.name,
						label = s.name,
						detail = s.hardware .. (if s.shape ~= "" then " (" .. s.shape .. ")" else ""),
						icon = colab.hardware_icon(s.hardware, s.variant),
					})
				end
			end
		end
		if #items == 0 then
			cx:toast("info", "No active named Colab sessions", "Orphaned [?] runtimes must be stopped in Colab web UI.")
			return
		end

		cx:pick({
			title = "Stop Colab Session",
			items = items,
		}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local active_cx = next_cx or cx
			local safe_name = colab.sanitize_name(item.id)
			if safe_name == nil then
				active_cx:toast("error", "Invalid session name", item.id)
				return
			end
			active_cx:toast("info", "Stopping Colab session…", safe_name)
			run_colab({ "stop", "-s", safe_name }, 20000, function(_res: ProcessResult?, stop_err: string?, detail: string?)
				if stop_err ~= nil then
					toast_cli_error(active_cx, "Failed to stop " .. safe_name, stop_err, detail or "")
					return
				end
				active_cx:toast("success", "Stopped Colab session", safe_name)
			end)
		end)
	end)
end

local function check_usage_flow(cx: WindowCx)
	run_colab({ "usage" }, 12000, function(res: ProcessResult?, err_kind: string?, err_detail: string?)
		if err_kind ~= nil or res == nil then
			toast_cli_error(cx, "Failed to check Colab usage", err_kind or "failed", err_detail or "")
			return
		end
		local usage = colab.parse_usage(res.stdout)
		if usage == nil then
			cx:toast("info", "Colab Compute Units", colab.first_line(res.stdout))
			return
		end
		cx:toast(
			"info",
			"Compute Units: " .. usage.balance,
			"Rate: " .. usage.rate .. " · Active: " .. usage.assignments
		)
	end)
end

local function open_glimpse_panel(cx: WindowCx)
	local created = cx:new_block(BLOCK_ID, nil, "glimpse", { focus = true })
	if created ~= nil then
		glimpse_panes[created] = true
	end
end

local function open_sessions_panel(cx: WindowCx)
	local existing = find_sessions_pane(cx)
	if existing ~= nil then
		if is_glimpse_pane(cx, existing) then
			glimpse_panes[existing.pane] = nil
			cx.layout:close(existing.pane)
			return
		end
		if existing.floating or existing.parked then
			cx.layout:close(existing.pane)
		else
			cx.layout:focus(existing.pane)
			return
		end
	end

	open_glimpse_panel(cx)
end

local function toggle_dock_panel(cx: WindowCx)
	local existing = find_sessions_pane(cx)
	if existing == nil then
		open_glimpse_panel(cx)
		return
	end
	if is_glimpse_pane(cx, existing) or existing.floating then
		local anchor = find_tiled_anchor(cx, existing.pane)
		glimpse_panes[existing.pane] = nil
		local ok = cx.layout:dock(existing.pane, anchor, "right", { focus = true })
		if not ok then
			cx.layout:close(existing.pane)
			cx:new_block(BLOCK_ID, nil, "beside", if anchor ~= nil then { target = anchor } else nil)
		end
		return
	end
	cx.layout:close(existing.pane)
	open_glimpse_panel(cx)
end

tern.command({
	id = "open",
	title = "Colab: Toggle Popup Panel",
	icon = "server",
	group = "Colab",
	keys = { "alt+shift+cmd+c" },
	available = desktop_available,
	run = open_sessions_panel,
})

tern.command({
	id = "toggle-dock",
	title = "Colab: Dock in Split / Popup",
	icon = "server",
	group = "Colab",
	available = desktop_available,
	run = toggle_dock_panel,
})

tern.command({
	id = "connect",
	title = "Colab: SSH Connect / Provision…",
	icon = "terminal",
	group = "Colab",
	keys = { "alt+shift+cmd+g" },
	available = desktop_available,
	run = start_connect_flow,
})

tern.command({
	id = "connect-rm",
	title = "Colab: Ephemeral SSH (--rm)…",
	icon = "bolt",
	group = "Colab",
	available = desktop_available,
	run = start_ephemeral_flow,
})

tern.command({
	id = "stop",
	title = "Colab: Stop Session…",
	icon = "stop",
	group = "Colab",
	available = desktop_available,
	run = stop_session_flow,
})

tern.command({
	id = "usage",
	title = "Colab: Check Compute Units",
	icon = "gauge",
	group = "Colab",
	available = desktop_available,
	run = check_usage_flow,
})

tern.command({
	id = "ssh-config",
	title = "Colab: Copy ~/.ssh/config Entry",
	icon = "copy",
	group = "Colab",
	available = desktop_available,
	run = start_ssh_config_flow,
})

tern.bind("alt+shift+cmd+c", "plugin.tern-colab.open")
tern.bind("alt+shift+cmd+g", "plugin.tern-colab.connect")

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local prefix = "colab-ssh://"
	if string.sub(link.url, 1, #prefix) ~= prefix then
		return nil
	end
	if not is_desktop() then
		cx:toast("error", "Colab SSH requires desktop Tern", nil)
		return { handled = true }
	end

	local rest = string.sub(link.url, #prefix + 1)
	local qpos = string.find(rest, "?", 1, true)
	local action = if qpos ~= nil then string.sub(rest, 1, qpos - 1) else rest
	local qs = if qpos ~= nil then string.sub(rest, qpos + 1) else ""

	if action == "connect" then
		local q = colab.parse_query(qs)
		local name = colab.sanitize_name(q.session)
		if name == nil then
			cx:toast("error", "Invalid Colab session link", link.url)
			return { handled = true }
		end
		launch_ssh(cx, { session = name }, name)
		return { handled = true }
	elseif action == "new" then
		start_connect_flow(cx)
		return { handled = true }
	elseif action == "new-rm" then
		start_ephemeral_flow(cx)
		return { handled = true }
	elseif action == "ssh-config" then
		start_ssh_config_flow(cx)
		return { handled = true }
	elseif action == "hide" then
		close_popup_panel(cx)
		return { handled = true }
	end

	cx:toast("error", "Unknown Colab action", action)
	return { handled = true }
end)
