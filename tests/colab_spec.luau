--!strict

local colab = require("../lib/colab")

local passed = 0
local failed = 0

local function assert_eq<T>(actual: T, expected: T, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %q, got %q", msg, tostring(expected), tostring(actual)), 2)
	end
end

local function assert_true(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function test(name: string, fn: () -> ())
	local ok, err = (pcall :: any)(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print(string.format("FAIL [%s]: %s", name, tostring(err)))
	end
end

test("trim strips surrounding whitespace", function()
	assert_eq(colab.trim("  hello\t\n "), "hello", "trim")
	assert_eq(colab.trim("   "), "", "trim blanks")
end)

test("shell_quote safely single-quotes POSIX arguments", function()
	assert_eq(colab.shell_quote(""), "''", "empty")
	assert_eq(colab.shell_quote("simple-arg_1.py"), "'simple-arg_1.py'", "plain word")
	assert_eq(colab.shell_quote("/path/with spaces/colab"), "'/path/with spaces/colab'", "spaces")
	assert_eq(colab.shell_quote("it's"), "'it'\\''s'", "single quote")
end)

test("sanitize_name accepts safe names and rejects metacharacters", function()
	assert_eq(colab.sanitize_name("train-t4_01.run"), "train-t4_01.run", "valid")
	assert_eq(colab.sanitize_name("  colab-v6e1  "), "colab-v6e1", "trimmed valid")
	assert_eq(colab.sanitize_name(nil), nil, "nil")
	assert_eq(colab.sanitize_name(""), nil, "empty")
	assert_eq(colab.sanitize_name("bad name"), nil, "space")
	assert_eq(colab.sanitize_name("bad;rm"), nil, "semicolon")
	assert_eq(colab.sanitize_name("$(whoami)"), nil, "subshell")
	assert_eq(colab.sanitize_name("a/b"), nil, "slash")
end)

test("url encode, decode, and parse_query round-trip", function()
	local raw = "exp 1+2=3&ok"
	local enc = colab.url_encode(raw)
	assert_eq(colab.url_decode(enc), raw, "round-trip")
	assert_eq(colab.url_decode("hello+world%21"), "hello world!", "plus and hex")
	local q = colab.parse_query("session=" .. colab.url_encode("my run") .. "&gpu=T4")
	assert_eq(q.session, "my run", "query session")
	assert_eq(q.gpu, "T4", "query gpu")
end)

test("candidate_bins prioritizes TERN_COLAB_BIN, HOME/.local/bin, and plugin_dir fallback", function()
	local bins = colab.candidate_bins(function(key: string): string?
		if key == "TERN_COLAB_BIN" then
			return "/custom/bin/colab"
		elseif key == "HOME" then
			return "/Users/tester"
		end
		return nil
	end)
	assert_eq(bins[1], "/custom/bin/colab", "override first")
	assert_eq(bins[2], "/Users/tester/.local/bin/colab", "HOME/.local/bin second")

	local derived = colab.candidate_bins(function(_key: string): string?
		return nil
	end, "/Users/alice/Documents/progs/tern-colab")
	assert_eq(derived[1], "/Users/alice/.local/bin/colab", "plugin_dir derives user home when HOME is nil")

	local dedup = colab.candidate_bins(function(key: string): string?
		if key == "TERN_COLAB_BIN" then
			return "/opt/homebrew/bin/colab"
		end
		return nil
	end)
	local count = 0
	for _, b in ipairs(dedup) do
		if b == "/opt/homebrew/bin/colab" then
			count += 1
		end
	end
	assert_eq(count, 1, "deduplicates identical candidates")

	local win = colab.candidate_bins(function(key: string): string?
		if key == "USERPROFILE" then
			return "C:\\Users\\tester"
		end
		return nil
	end)
	assert_eq(win[1], "C:\\Users\\tester/.local/bin/colab.exe", "windows exe first")
end)

test("parse_sessions parses named and orphaned Colab CLI lines", function()
	local out = table.concat({
		"[train-t4] https://8080-m-s-abc.us-west1.colab.dev | Hardware: T4 | Shape: HIGHMEM | Variant: GPU",
		"[?] https://8080-m-s-xyz.colab.dev | Hardware: A100 | Shape: STANDARD | Variant: GPU",
		"[tpu-run] ep-1 | Hardware: v6e1 | Shape: Standard | Variant: TPU",
	}, "\r\n")
	local sessions = colab.parse_sessions(out)
	assert_eq(#sessions, 3, "session count")
	assert_eq(sessions[1].name, "train-t4", "s1 name")
	assert_eq(sessions[1].hardware, "T4", "s1 hw")
	assert_eq(sessions[1].shape, "HIGHMEM", "s1 shape")
	assert_eq(sessions[1].variant, "GPU", "s1 variant")
	assert_eq(sessions[1].orphaned, false, "s1 not orphaned")

	assert_eq(sessions[2].name, "?", "s2 orphaned marker")
	assert_eq(sessions[2].orphaned, true, "s2 orphaned true")

	assert_eq(sessions[3].variant, "TPU", "s3 variant")
	assert_eq(#colab.parse_sessions("No active sessions.\n"), 0, "empty output")
end)

test("parse_usage parses balance, rate, and assignments", function()
	local out = table.concat({
		"Current balance: 98.42 compute units",
		"Usage rate: 1.96/hr",
		"Active assignments: 2",
	}, "\n")
	local usage = colab.parse_usage(out)
	assert_true(usage ~= nil, "usage parsed")
	if usage ~= nil then
		assert_eq(usage.balance, "98.42", "balance")
		assert_eq(usage.rate, "1.96/hr", "rate")
		assert_eq(usage.assignments, "2", "assignments")
	end
	assert_true(colab.parse_usage("unrecognized") == nil, "missing fields yields nil")
end)

test("presets lookup and hardware icons work", function()
	local t4 = colab.find_preset("t4")
	assert_true(t4 ~= nil, "t4 preset exists")
	if t4 ~= nil then
		assert_eq(t4.gpu, "T4", "t4 gpu flag")
		assert_eq(t4.high_mem, false, "t4 high_mem")
	end
	local a100h = colab.find_preset("a100-high")
	assert_true(a100h ~= nil, "a100-high preset exists")
	if a100h ~= nil then
		assert_eq(a100h.gpu, "A100", "a100 gpu flag")
		assert_eq(a100h.high_mem, true, "a100 high_mem")
	end
	assert_true(colab.find_preset("nonexistent") == nil, "unknown preset")
	assert_eq(colab.hardware_icon("T4", "GPU"), "bolt", "t4 gpu icon")
	assert_eq(colab.hardware_icon("A100", "GPU"), "flame", "a100 gpu icon")
	assert_eq(colab.hardware_icon("H100", "GPU"), "rocket", "h100 gpu icon")
	assert_eq(colab.hardware_icon("v6e1", "TPU"), "sparkle", "tpu icon")
	assert_eq(colab.hardware_icon("CPU", "DEFAULT"), "cpu", "cpu icon")
end)

test("build_ssh_command builds expected CLI arguments", function()
	local cmd = colab.build_ssh_command("/opt/bin/colab", {
		session = "ml-exp",
		gpu = "L4",
		high_mem = true,
		rm = true,
	})
	assert_eq(cmd, "'/opt/bin/colab' 'ssh' '-s' 'ml-exp' '--gpu' 'L4' '--high-mem' '--rm'", "quoted command")

	local spaced = colab.build_ssh_command("/Applications/Colab CLI/colab", {
		session = "box",
		tpu = "v5e1",
	})
	assert_eq(spaced, "'/Applications/Colab CLI/colab' 'ssh' '-s' 'box' '--tpu' 'v5e1'", "spaced binary command")
end)

test("build_ssh_config_entry generates ProxyCommand stanza", function()
	local t4 = colab.find_preset("t4-high")
	assert_true(t4 ~= nil, "t4-high exists")
	if t4 ~= nil then
		local entry = colab.build_ssh_config_entry("/Users/me/.local/bin/colab", t4, "colab-t4h")
		assert_true(string.find(entry, "Host colab-t4h", 1, true) ~= nil, "Host line")
		assert_true(string.find(entry, "ProxyCommand", 1, true) ~= nil, "ProxyCommand line")
		assert_true(string.find(entry, "--proxy-mode", 1, true) ~= nil, "--proxy-mode flag")
		assert_true(string.find(entry, "--gpu T4", 1, true) ~= nil, "--gpu flag")
		assert_true(string.find(entry, "--high-mem", 1, true) ~= nil, "--high-mem flag")
	end
end)

test("build_new_args builds `colab new` arguments from presets", function()
	local function args_for(preset_id: string): string
		local preset = colab.find_preset(preset_id)
		assert_true(preset ~= nil, preset_id .. " preset exists")
		if preset == nil then
			return ""
		end
		return table.concat(colab.build_new_args("ml-exp", preset), " ")
	end

	assert_eq(args_for("cpu"), "new -s ml-exp", "cpu")
	assert_eq(args_for("cpu-high"), "new -s ml-exp --high-mem", "cpu high-mem")
	assert_eq(args_for("t4-high"), "new -s ml-exp --gpu T4 --high-mem", "t4 high-mem")
	assert_eq(args_for("v5e1"), "new -s ml-exp --tpu v5e1", "tpu")
end)

test("classify_error categorizes auth and ssh key errors", function()
	local k1 = colab.classify_error(1, "Error: User is unauthenticated. Run login.", "")
	assert_eq(k1, "auth", "auth classified")
	local k2 = colab.classify_error(1, "Unsupported ssh-rsa key; ed25519 required", "")
	assert_eq(k2, "key", "key classified")
	local k3, d3 = colab.classify_error(2, "\n  connection reset by peer  \n", "")
	assert_eq(k3, "failed", "generic failed")
	assert_eq(d3, "connection reset by peer", "first line detail")
end)

print(string.format("colab_spec: %d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
