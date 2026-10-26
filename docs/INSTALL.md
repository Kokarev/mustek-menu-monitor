# Installation and NUT setup

These are instructions for a future installation, not an automatic installer.
During local publication preparation, do not execute them against an existing
deployment. Keep any existing application, LaunchAgent, UPS service and data
unchanged until a separate deployment decision.

## NUT prerequisite and configuration

Install and configure NUT independently using its
[official documentation](https://networkupstools.org/documentation.html).
No NUT configuration files or credentials are included here. The monitor needs
read access through `upsc`; it does not use `upsd.users` credentials or control
commands. Keep the server on an appropriate trusted interface for your setup.

Use demonstration target `demo-ups@127.0.0.1:3493` only as a placeholder for your
own NUT UPS name and server. In `Upsc.swift`, set the executable path and target
to your installation, then build. The application requires `ups.status`,
`input.voltage` and `ups.load` to accept a reading. `upsc` is given a three-second
timeout, followed by termination and, if necessary, a kill of that client child.
This does not stop the NUT server or driver.

Update the example battery profile in `Battery.swift` for your own hardware.
In the settings window, enter the UPS nominal output power in watts, or leave
it empty when unknown. An empty rating disables new power/energy estimates
without discarding previously recorded energy. No history is recalculated when
the rating changes.

## Fresh manual installation

Build first. The following refuses to overwrite an existing app:

```sh
test ! -e "$HOME/Applications/MustekMenuMonitor.app" || exit 1
mkdir -p "$HOME/Applications"
ditto dist/MustekMenuMonitor.app "$HOME/Applications/MustekMenuMonitor.app"
codesign --verify --deep --strict "$HOME/Applications/MustekMenuMonitor.app"
```

For interactive use, launch the app from Finder. It has a menu bar item and no
Dock icon. Ad hoc signing is for local builds; downloaded binaries may require
additional macOS review. No blanket Gatekeeper bypass is part of this project.
Do not run an older version alongside this app: older builds may lack the lock.

## Optional LaunchAgent for login startup

`examples/local.mustek.menumonitor.plist.in` is an inactive template, not an
installed agent. Its `__HOME__` marker must be replaced; launchd does not expand
`~` or shell variables inside ProgramArguments. For a fresh installation only,
render the template without overwriting an existing agent:

```sh
python3 - <<'PY'
from pathlib import Path
import plistlib
home = Path.home()
source = Path('examples/local.mustek.menumonitor.plist.in')
data = plistlib.loads(source.read_bytes())
data['ProgramArguments'] = [str(home / 'Applications/MustekMenuMonitor.app/Contents/MacOS/MustekMenuMonitor')]
for key in ('StandardOutPath', 'StandardErrorPath'):
    data[key] = str(home / 'Library/Logs/MustekMenuMonitor.log')
target = home / 'Library/LaunchAgents/local.mustek.menumonitor.plist'
target.parent.mkdir(parents=True, exist_ok=True)
(home / 'Library/Logs').mkdir(parents=True, exist_ok=True)
with target.open('xb') as stream:
    plistlib.dump(data, stream)
PY
plutil -lint "$HOME/Library/LaunchAgents/local.mustek.menumonitor.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.mustek.menumonitor.plist"
```

`RunAtLoad=true` launches it when the agent is loaded, including login.
**KeepAlive=false means no automatic restart after quit or crash.** A loaded
agent can be started manually when its application is stopped:

```sh
launchctl kickstart "gui/$(id -u)/local.mustek.menumonitor"
```

Do not use `kickstart -k` to manage a healthy instance. After SIGKILL, the kernel
releases the file lock even if `.lock` remains; the next instance acquires it
and updates the PID. Do not delete the lock file while an instance runs.

To disable a future installation's agent, use `launchctl bootout` with that
agent's domain and plist path. Preserve measurement files separately when
uninstalling. This guide does not authorize changes to any existing deployment.
