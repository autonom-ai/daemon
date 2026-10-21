# Installation

The daemon installs for the current user. It needs no `sudo`, writes only into the user data, command, and configuration directories, and never touches a configuration, `.env`, session, or log it did not create.

## Install

Build the command as your normal user, then run the installer:

```sh
dub build --compiler=ldc2 --config=daemon
python3 install.py
```

`install.py` builds the command when it is not built yet. Pass `--no-build` to install the runtime that is already built.

The installer places the command and its runtime where the daemon expects them:

| Path | Contents |
| --- | --- |
| `$XDG_DATA_HOME/autonom/bin/autonom` | The D command. |
| `$XDG_DATA_HOME/autonom/source/mcp/` | The MCP proxy and its helpers. |
| `$XDG_DATA_HOME/autonom/templates/` | The configuration, policy, and hook assets. |
| `~/.local/bin/autonom` | A link to the command, so its resource root stays deterministic. |
| `$XDG_CONFIG_HOME/autonom/config.yml` | The configuration, created only when it is missing. |

`$XDG_DATA_HOME` defaults to `~/.local/share` and `$XDG_CONFIG_HOME` to `~/.config`. The command is not on `PATH` unless `~/.local/bin` is; the installer reports that and prints the line to add:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The Devin CLI hooks and the MCP server registration use the command by name, so `~/.local/bin` has to be on the `PATH` of the processes that start them.

## Check

```sh
python3 install.py --check
```

The report names the command, the installed runtime, the configuration, and whether the command directory is on `PATH`.

## Uninstall

```sh
python3 install.py --uninstall
```

Uninstalling removes the command link and the runtime files the installer placed. It leaves the configuration, the `.env` beside it, the session data, the transcripts, and the logs alone, and it never removes files it did not write.

## Test prefix

`--prefix` installs into a directory of your choice instead of the user directories. The layout follows the same shape, so the command, the runtime, and the configuration stay separate from the real installation:

```sh
python3 install.py --prefix /tmp/autonom-prefix --no-build
```

The installer tests use only temporary prefixes.
