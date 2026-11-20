# AGENTS.md

## What this fork is

This is a fork of [dbydd/tern-colab](https://github.com/dbydd/tern-colab) at commit `f9fc0d1`. It carries two local fixes for Windows with google-colab-cli 0.8.0.

1. **PowerShell call operator and executable path.** `launch_ssh` in `window.luau` prepends `&` to the SSH command when `tern.runtime.os` is `"windows"`. Tern runs pane commands through the login shell, which stays PowerShell. PowerShell needs the call operator before a quoted executable, or it exits with `UnexpectedToken`. The window half also treats drive-letter paths as absolute, and `candidate_bins` includes `%USERPROFILE%/.local/bin/colab.exe`, so `tern.process.run` starts the CLI from the window process instead of falling back to bare `colab`. `resolve_bin` also ignores a cached bare `colab` from the host half, because the window process does not share the host half's shell PATH.
2. **CLI 0.8.0 provisioning.** `colab ssh -s NEW` in interactive mode does not create a session, and `colab new -s NAME` has no duplicate-name check. The fork creates runtimes with `colab new` through `Colab.build_new_args`, checks `colab sessions` before creating, attaches when the name already exists, and implements ephemeral by stopping the runtime when its pane closes. A 2 s poll of `cx.session:pane` enforces the stop because `pane_closed` was not delivered to a plugin linked into the running window.

## Upstream

`origin` is the upstream repository, `https://github.com/dbydd/tern-colab`. The fork tracks `origin/main` from base commit `f9fc0d1`.

Sync with upstream:

```sh
git fetch origin
git rebase origin/main
```

After a rebase, re-check the local fixes:

- Keep the `&` prefix block and the `tern.runtime.os == "windows"` guard in `launch_ssh`. If upstream changes `launch_ssh` or `build_ssh_command`, confirm the prefix still lands after `colab.build_ssh_command` and still reaches `open_ssh_pane`.
- Keep the `colab sessions` check in `prompt_and_launch_preset`, the `colab new` call through `Colab.build_new_args`, and the ephemeral stop in the `pane_closed` handler. If upstream changes `run_colab`, `fetch_sessions`, or `prompt_and_launch_preset`, re-thread the fresh callback `cx` through them.

## Keep these upstream-compatible

The local changes are limited to `lib/colab.luau`, `window.luau`, `host.luau`, and `tests/colab_spec.luau`.

- `lib/colab.luau` adds `build_new_args` and the Windows `USERPROFILE` candidates. Keep `build_ssh_argv`, `build_ssh_command`, and `build_ssh_config_entry` unchanged.
- `window.luau` keeps the `&` prefix Windows-only, so POSIX commands stay unchanged. It also treats drive-letter paths as absolute and adds the provisioning and ephemeral flows. Do not move the Windows quoting into `lib/colab.luau` or change the POSIX quoting.
- `host.luau` differs only in the `e` key comment and the `btn_new_rm` title.
- `tests/colab_spec.luau` adds a `build_new_args` test alongside the upstream tests.

`plugin.toml` differs from upstream because it carries the fork version. Keep the version bump when you rebase. `README.md` stays upstream; do not edit it.

## Tests

From the fork root, run either command:

```sh
luau tests/colab_spec.luau
lune run tests/colab_spec.luau
```

Expected output: `colab_spec: 12 passed, 0 failed`.

## End-to-end checks

Link the plugin and open a Tern window on Windows:

```sh
tern plugin link .
```

**New.** Run `Colab: SSH Connect / Provision…`, pick a preset, and leave the name blank or type a fresh name. Confirm `colab new` provisions the runtime, the SSH pane starts with `& 'colab' 'ssh' -s <name>`, and the pane does not exit with `UnexpectedToken`. Re-run the flow with the same name; Tern attaches to the existing session instead of provisioning a second runtime.

**Ephemeral.** Run `Colab: Ephemeral SSH…` and pick a fresh name. Close the SSH pane and confirm `colab sessions` no longer lists the runtime within a few seconds. Running the flow with an existing name is rejected.

These checks need a working `colab` install, a sign-in, and an Ed25519 or ECDSA SSH key. To check the PowerShell quoting alone:

```sh
powershell.exe -NoProfile -Command "& 'colab' 'ssh' '--help'"
```

## Do not

- Do not rely on bare `colab` for `run_colab`. The window process may not have the shell's PATH; resolve `%USERPROFILE%/.local/bin/colab.exe` or set `TERN_COLAB_BIN`.
- Do not call `colab new` without checking `colab sessions` first. google-colab-cli 0.8.0 does not reject duplicate names, and `colab new -s NAME` calls `state.store.add`, which creates a second runtime under the same name.
- Do not rely on `--rm` for cleanup. The CLI ignores it unless `colab ssh` created the runtime. Ephemeral stops the runtime when its pane closes; it leaks if Tern quits before the poll runs.
- Do not rely on `pane_closed` alone for ephemeral cleanup. Keep the 2 s pane poll; the event did not fire for a plugin linked into the running window.
- Do not commit personal data. This includes Colab session names, endpoints, compute-unit balances, SSH keys, tokens, and local paths from a real run. Use placeholders such as `train-t4` in tests and docs.
- Do not link the plugin while an edit is half-applied. Tern hot-reloads a linked plugin, so an open window can run a partial `window.luau`.
- Do not change Tern's login shell or the user's `~/.ssh/config` from this repo. The fork assumes PowerShell and documents the assumption. It does not configure either.
