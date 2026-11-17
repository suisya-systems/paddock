# 0016. On WSL, an opt-in user service starts the core at boot with hc on its PATH

Status: **proposed** (2026-11-17). Built with this record: `org-start.sh --setup-wsl`, a line in `--check`'s `core-path` fix on WSL, and the README section [After a Windows restart](../../README.md#after-a-windows-restart-wsl).

## The problem

After a Windows restart every WSL process is gone. The first `hc` client to run then starts a new core, and on WSL that is often herdr-app for Windows. That core has no `~/.local/bin` on its PATH, so its terminals cannot run `hc` or `claude`, and the person has to run `org-start.sh --restart-core` from a login shell outside herdr every time.

## What was found (the installed hc on WSL2, 2026-11-17, read only)

| Fact | Evidence |
| --- | --- |
| The core runs as a transient systemd user unit `hc-serve-<hash>.service`. The launching `hc` writes its own environment to `EnvironmentFile=/run/user/<uid>/hc-serve-<hash>/environment`; the unit has no `Environment=`. | `/run/user/<uid>/systemd/transient/hc-serve-*.service`; the environment file holds the launching login shell's variables (`_=…/.local/bin/hc`, `SHLVL=2`, the full PATH). `herdr-core` strings: `EnvironmentFile=`, `UnsetEnvironment=`, `core: … using the next launcher's environment`. |
| So the core's PATH is its launcher's PATH. The systemd user manager's environment (`systemctl --user show-environment`, and so `~/.config/environment.d`) is only the base, and the file's PATH replaces it. | The same unit file; the manager's PATH is the short default and the core's is not. |
| herdr-app for Windows reaches WSL with the machine's `--via`, which `hc machine add --help` gives as `wsl.exe -d Ubuntu -e sh -c` (this README's step 2). `-e` runs `sh` with no shell of the person's; a non-interactive `sh -c` (dash) reads no startup file. The line it runs finds `herdr-core` by `command -v`, else `$HOME/.local/bin/herdr-core`, then `exec … connect`, which starts a core when none runs. | `herdr-core` strings: `p=$(command -v herdr-core) \|\| p=$HOME/.local/bin/herdr-core; … exec "$p" connect`, and the `--via` help text. |
| Linger was already on for the person (`/var/lib/systemd/linger/<user>`); `hc` turns it on itself (`hc: turned on linger for …`). | The file, and the `herdr-core` strings. |

Hence `~/.zshenv`, `~/.bashrc`, `~/.profile` and `~/.config/environment.d/*.conf` do not reach a core that the documented `--via` starts. A core started before herdr-app connects does keep its PATH, since `connect` then finds it running.

## Decision

`org-start.sh --setup-wsl` (WSL only, typed by the person once) writes one file of its own, `~/.config/systemd/user/paddock-core.service`: a oneshot user service, wanted by `default.target`, that runs `hc server start` with `Environment=PATH=` set to the person's login-shell PATH at setup time (entries under `/mnt` and with characters systemd would read differently are left out) `SHELL=` their login shell, and `WSL_INTEROP=/run/WSL/1_interop` (the interop socket WSL's init keeps for the whole boot; a boot service gets none) with `WSL_DISTRO_NAME`, and the shell's `XDG_*_HOME` and paddock folder variables (`PADDOCK_STATE_DIR`, `PADDOCK_BIN_DIR` and the other `*_DIR` ones org-start and the templates read; never a runtime one such as `PADDOCK_ORG_ID`). The file is always under `~/.config`, since the user manager starts at boot without the shell's `XDG_CONFIG_HOME`. It enables the service and turns linger on when it is off, so the user manager starts with WSL, before any login. It shows the file and the commands and asks y/N (`--yes` skips the question), is idempotent (identical file, enabled, linger on: nothing to ask), refuses a `paddock-core.service` it did not write, and refuses inside an agent.

Not chosen: shell startup files and `environment.d` (the facts above show they are not read on this path); changing the `--via` to a login shell (a Windows-side herdr setting, which paddock does not write, and which needs the PATH set in a file a login `sh` reads).

## Departs from "nothing to install beyond herdr and those tools"

This is the first paddock step that writes a file in the person's own configuration outside paddock's folders. It is opt-in: nothing runs it but the person, the file and every command are shown before anything is written, and undoing it is two steps (`systemctl --user disable paddock-core.service`, then delete the file). The alternative is the person running `--restart-core`, which ends every terminal, after each Windows restart.

## Unverified

- **The order at boot.** WSL is started by herdr-app's own `wsl.exe` call. Whether the user manager runs the service before that call's `connect` starts a core was not measured. If `connect` wins, the core still lacks the PATH, `--check` still says so, and `--restart-core` still fixes it. The person's one test: `wsl --shutdown` in PowerShell, open herdr-app, then `org-start.sh --check` shows `ok core-path`.
- **Windows programs from such a core's terminals.** The service sets `WSL_INTEROP=/run/WSL/1_interop` (on this machine a link to init's socket `/run/WSL/2_interop`, there since boot); that a terminal of such a core can run `powershell.exe` (the watcher's toast) was not measured.

## Revisit when

The boot test fails (then: have the service restart a core that lacks the PATH while no terminal is live, or document the `--via` change), or herdr starts the core with the user manager's environment or a login shell itself.
