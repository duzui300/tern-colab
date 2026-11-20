--!strict
-- Shared helpers for tern-colab (used by host.luau, window.luau, and unit tests).

export type Preset = {
	id: string,
	label: string,
	detail: string,
	icon: string,
	gpu: string?,
	tpu: string?,
	high_mem: boolean,
}

export type SessionInfo = {
	key: string,
	name: string,
	endpoint: string,
	hardware: string,
	shape: string,
	variant: string,
	orphaned: boolean,
}

export type UsageInfo = {
	balance: string,
	rate: string,
	assignments: string,
}

export type SshLaunchOpts = {
	session: string?,
	gpu: string?,
	tpu: string?,
	high_mem: boolean?,
	rm: boolean?,
	proxy_mode: boolean?,
	identity: string?,
}

local Colab = {}

Colab.PRESETS = {
	{ id = "cpu", label = "CPU (Standard)", detail = "Default CPU runtime", icon = "cpu", gpu = nil, tpu = nil, high_mem = false },
	{ id = "cpu-high", label = "CPU (High-RAM)", detail = "High-memory CPU (Pro)", icon = "cpu", gpu = nil, tpu = nil, high_mem = true },
	{ id = "t4", label = "GPU T4", detail = "NVIDIA T4", icon = "bolt", gpu = "T4", tpu = nil, high_mem = false },
	{ id = "t4-high", label = "GPU T4 (High-RAM)", detail = "NVIDIA T4 · High-RAM", icon = "bolt", gpu = "T4", tpu = nil, high_mem = true },
	{ id = "l4", label = "GPU L4", detail = "NVIDIA L4", icon = "bolt", gpu = "L4", tpu = nil, high_mem = false },
	{ id = "g4", label = "GPU G4", detail = "NVIDIA G4", icon = "bolt", gpu = "G4", tpu = nil, high_mem = false },
	{ id = "a100", label = "GPU A100", detail = "NVIDIA A100", icon = "flame", gpu = "A100", tpu = nil, high_mem = false },
	{ id = "a100-high", label = "GPU A100 (High-RAM)", detail = "NVIDIA A100 · High-RAM", icon = "flame", gpu = "A100", tpu = nil, high_mem = true },
	{ id = "h100", label = "GPU H100", detail = "NVIDIA H100", icon = "rocket", gpu = "H100", tpu = nil, high_mem = false },
	{ id = "h100-high", label = "GPU H100 (High-RAM)", detail = "NVIDIA H100 · High-RAM", icon = "rocket", gpu = "H100", tpu = nil, high_mem = true },
	{ id = "v5e1", label = "TPU v5e1", detail = "Cloud TPU v5e", icon = "sparkle", gpu = nil, tpu = "v5e1", high_mem = false },
	{ id = "v6e1", label = "TPU v6e1", detail = "Cloud TPU v6e", icon = "sparkle", gpu = nil, tpu = "v6e1", high_mem = false },
} :: { Preset }

function Colab.trim(s: string): string
	local trimmed = string.gsub(s, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	return trimmed
end

function Colab.shell_quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function Colab.sanitize_name(raw: string?): string?
	if raw == nil then
		return nil
	end
	local s = Colab.trim(raw)
	if s == "" then
		return nil
	end
	if string.match(s, "^[%w%.%-_]+$") == nil then
		return nil
	end
	return s
end

function Colab.url_encode(s: string): string
	local encoded = string.gsub(s, "([^%w%-_%.~])", function(ch: string): string
		return string.format("%%%02X", string.byte(ch))
	end)
	return encoded
end

function Colab.url_decode(s: string): string
	local with_spaces = string.gsub(s, "+", " ")
	local decoded = string.gsub(with_spaces, "%%(%x%x)", function(hex: string): string
		local code = tonumber(hex, 16)
		if code then
			return string.char(code)
		end
		return "%" .. hex
	end)
	return decoded
end

function Colab.parse_query(qs: string?): { [string]: string }
	local params: { [string]: string } = {}
	if qs == nil or qs == "" then
		return params
	end
	for pair in string.gmatch(qs, "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=(.*)$")
		if k and v then
			params[Colab.url_decode(k)] = Colab.url_decode(v)
		else
			params[Colab.url_decode(pair)] = ""
		end
	end
	return params
end

function Colab.resolve_home(getenv: (string) -> string?, plugin_dir: string?): string?
	local home = getenv("HOME")
	if home and home ~= "" then
		return home
	end
	if plugin_dir and plugin_dir ~= "" then
		local mac_home = string.match(plugin_dir, "^(/Users/[^/]+)")
		if mac_home then
			return mac_home
		end
		local linux_home = string.match(plugin_dir, "^(/home/[^/]+)")
		if linux_home then
			return linux_home
		end
	end
	return nil
end

function Colab.candidate_bins(getenv: (string) -> string?, plugin_dir: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(path: string?)
		if path and path ~= "" and not seen[path] then
			seen[path] = true
			table.insert(out, path)
		end
	end

	add(getenv("TERN_COLAB_BIN"))
	local userprofile = getenv("USERPROFILE")
	if userprofile and userprofile ~= "" then
		add(userprofile .. "/.local/bin/colab.exe")
		add(userprofile .. "/.local/bin/colab")
	end
	local home = Colab.resolve_home(getenv, plugin_dir)
	if home then
		add(home .. "/.local/bin/colab")
		add(home .. "/.cargo/bin/colab")
	end
	add("/opt/homebrew/bin/colab")
	add("/usr/local/bin/colab")
	add("/usr/bin/colab")
	add("colab")
	return out
end

function Colab.parse_sessions(stdout: string): { SessionInfo }
	local list: { SessionInfo } = {}
	for line in string.gmatch(stdout, "[^\r\n]+") do
		local name, endpoint, hw, shape, variant = string.match(
			line,
			"^%[([^%]]+)%]%s+([^%s|]+)%s*|%s*Hardware:%s*([^|]+)%s*|%s*Shape:%s*([^|]+)%s*|%s*Variant:%s*(.+)$"
		)
		if name and endpoint and hw and shape and variant then
			local clean_name = Colab.trim(name)
			local clean_endpoint = Colab.trim(endpoint)
			local orphaned = clean_name == "?"
			table.insert(list, {
				key = if orphaned then "orphan:" .. clean_endpoint else "sess:" .. clean_name,
				name = clean_name,
				endpoint = clean_endpoint,
				hardware = Colab.trim(hw),
				shape = Colab.trim(shape),
				variant = Colab.trim(variant),
				orphaned = orphaned,
			})
		end
	end
	return list
end

function Colab.parse_usage(stdout: string): UsageInfo?
	local balance = string.match(stdout, "Current balance:%s*([%d%.]+)")
	local rate = string.match(stdout, "Usage rate:%s*([%d%.]+/hr)")
	local assignments = string.match(stdout, "Active assignments:%s*(%d+)")
	if not balance and not rate and not assignments then
		return nil
	end
	return {
		balance = balance or "?",
		rate = rate or "?/hr",
		assignments = assignments or "?",
	}
end

function Colab.hardware_icon(hardware: string, variant: string): string
	local hw = string.upper(hardware)
	if hw == "H100" then
		return "rocket"
	elseif hw == "A100" then
		return "flame"
	elseif string.upper(variant) == "TPU" or string.sub(hw, 1, 1) == "V" then
		return "sparkle"
	elseif string.upper(variant) == "GPU" or hw == "T4" or hw == "L4" or hw == "G4" then
		return "bolt"
	end
	return "cpu"
end

function Colab.build_ssh_argv(bin: string, opts: SshLaunchOpts): { string }
	local argv: { string } = { bin, "ssh" }
	if opts.proxy_mode then
		table.insert(argv, "--proxy-mode")
	end
	local sess = Colab.sanitize_name(opts.session)
	if sess then
		table.insert(argv, "-s")
		table.insert(argv, sess)
	end
	if opts.gpu and opts.gpu ~= "" then
		table.insert(argv, "--gpu")
		table.insert(argv, opts.gpu)
	elseif opts.tpu and opts.tpu ~= "" then
		table.insert(argv, "--tpu")
		table.insert(argv, opts.tpu)
	end
	if opts.high_mem then
		table.insert(argv, "--high-mem")
	end
	if opts.rm then
		table.insert(argv, "--rm")
	end
	if opts.identity and opts.identity ~= "" then
		table.insert(argv, "-i")
		table.insert(argv, opts.identity)
	end
	return argv
end

function Colab.build_ssh_command(bin: string, opts: SshLaunchOpts): string
	local argv = Colab.build_ssh_argv(bin, opts)
	local parts: { string } = {}
	for i, arg in argv do
		parts[i] = Colab.shell_quote(arg)
	end
	return table.concat(parts, " ")
end

function Colab.build_ssh_config_entry(bin: string, preset: Preset, session_name: string?): string
	local alias = Colab.sanitize_name(session_name) or ("colab-" .. preset.id)
	local proxy_argv = Colab.build_ssh_argv(bin, {
		proxy_mode = true,
		session = alias,
		gpu = preset.gpu,
		tpu = preset.tpu,
		high_mem = preset.high_mem,
	})
	local quoted: { string } = {}
	for i, part in proxy_argv do
		if string.find(part, "[%s'\"]") then
			quoted[i] = Colab.shell_quote(part)
		else
			quoted[i] = part
		end
	end
	local lines = {
		"Host " .. alias,
		"  HostName colab-runtime",
		"  User root",
		"  ProxyCommand " .. table.concat(quoted, " "),
		"  StrictHostKeyChecking no",
		"  UserKnownHostsFile /dev/null",
		"  ServerAliveInterval 30",
	}
	return table.concat(lines, "\n")
end

function Colab.build_new_args(session_name: string, preset: Preset): { string }
	local args: { string } = { "new", "-s", session_name }
	if preset.gpu and preset.gpu ~= "" then
		table.insert(args, "--gpu")
		table.insert(args, preset.gpu)
	elseif preset.tpu and preset.tpu ~= "" then
		table.insert(args, "--tpu")
		table.insert(args, preset.tpu)
	end
	if preset.high_mem then
		table.insert(args, "--high-mem")
	end
	return args
end

function Colab.find_preset(id: string?): Preset?
	if not id then
		return nil
	end
	for _, p in Colab.PRESETS do
		if p.id == id then
			return p
		end
	end
	return nil
end

function Colab.first_line(s: string): string
	local trimmed = Colab.trim(s)
	local line = string.match(trimmed, "^([^\r\n]+)")
	return line or trimmed
end

function Colab.classify_error(status: number, stderr: string, stdout: string): (string, string)
	local combined = stderr .. "\n" .. stdout
	local lower = string.lower(combined)
	if string.find(lower, "oauth", 1, true)
		or string.find(lower, "credentials", 1, true)
		or string.find(lower, "login", 1, true)
		or string.find(lower, "401", 1, true)
		or string.find(lower, "unauthenticated", 1, true)
	then
		return "auth", Colab.first_line(combined)
	end
	if string.find(lower, "no ssh public key", 1, true)
		or string.find(lower, "unsupported key type", 1, true)
		or string.find(lower, "ssh-rsa", 1, true)
		or string.find(lower, "ed25519", 1, true)
	then
		return "key", Colab.first_line(combined)
	end
	local detail = Colab.first_line(if stderr ~= "" then stderr else stdout)
	if detail == "" then
		detail = "colab exited with status " .. tostring(status)
	end
	return "failed", detail
end

return Colab
