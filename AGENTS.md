# AGENTS.md

## What this fork is

This is a fork of [dbydd/tern-colab](https://github.com/dbydd/tern-colab) at commit `f9fc0d1`. It carries one Windows-only change. `launch_ssh` in `window.luau` prepends the PowerShell call operator (`&`) to the SSH command when `tern.runtime.os` is `"windows"`. Tern runs pane commands through the login shell. PowerShell needs the call operator before a quoted executable, or it exits with `UnexpectedToken`.

## Upstream

`origin` is the upstream repository, `https://github.com/dbydd/tern-colab`. The fork tracks `origin/main` from base commit `f9fc0d1`.

Sync with upstream:

```sh
git fetch origin
git rebase origin/main
```

After a rebase, re-check the Windows line in `launch_ssh`. Keep the `&` prefix block and the `tern.runtime.os == "windows"` guard. If upstream changes `launch_ssh` or `build_ssh_command`, confirm the prefix still lands after `colab.build_ssh_command` and still reaches `open_ssh_pane`.

## Keep these upstream-compatible

Only `launch_ssh` in `window.luau` differs from upstream behavior. `lib/colab.luau`, `host.luau`, and `tests/colab_spec.luau` stay unchanged from upstream. Do not move the Windows handling into `lib/colab.luau`, add a helper function, or change the POSIX quoting. A Windows-only guard in `window.luau` leaves POSIX commands unchanged.

`plugin.toml` differs from upstream because it carries the fork version. Keep the version bump when you rebase. Keep `README.md` upstream.

## Tests

From the fork root, run either command:

```sh
luau tests/colab_spec.luau
lune run tests/colab_spec.luau
```

Expected output: `colab_spec: 11 passed, 0 failed`.

## End-to-end check

After an edit is complete, link the plugin and open a Tern window on Windows:

```sh
tern plugin link .
```

Run `Colab: SSH Connect / Provision…`, choose a session or preset, and confirm the new pane reaches the Colab CLI without exiting with `UnexpectedToken`. The pane now starts with `& 'colab' 'ssh'`. This check needs a working `colab` install, a sign-in, and an Ed25519 or ECDSA SSH key.

To check the PowerShell quoting alone:

```sh
powershell.exe -NoProfile -Command "& 'colab' 'ssh' '--help'"
```

## Do not

- Do not commit personal data. This includes Colab session names, endpoints, compute-unit balances, SSH keys, tokens, and local paths from a real run. Use placeholders such as `train-t4` in tests and docs.
- Do not link the plugin while an edit is half-applied. Tern hot-reloads a linked plugin, so an open window can run a partial `window.luau`.
- Do not change Tern's login shell or the user's `~/.ssh/config` from this repo. The fork assumes PowerShell and documents the assumption. It does not configure either.
