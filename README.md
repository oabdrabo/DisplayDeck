---

## Smart installer, aliases and safety watchdog

This fork adds an optional smart installer on top of the original `display_disable` binary.

The smart installer can:

- install `display_disable` if it is missing
- detect the built-in display ID automatically
- create shell aliases such as `s-off` and `s-on`
- install an optional safety watchdog
- register trusted external displays
- fully uninstall the smart setup and the `display_disable` binary

### Smart install

Run:

```bash
./scripts/install_smart.sh
```

The installer detects the built-in display ID using:

```bash
display_disable list
```

Default aliases:

```bash
s-off
s-on
trust-displays
```

Where:

- `s-off` disables the built-in display
- `s-on` re-enables the built-in display
- `trust-displays` adds the currently connected external displays to the trusted display list

After installation, reload your shell:

```bash
source ~/.zshrc
```

### Safety watchdog

The optional watchdog is designed to avoid being left without an active built-in display when the external display is disconnected.

It is installed as:

```text
~/Scripts/DisplayDisabler-Watchdog
```

and runs through this LaunchAgent:

```text
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
```

LaunchAgent label:

```text
com.displaydisabler.watchdog
```

If the built-in display is disabled and no trusted external display is detected, the watchdog waits for a configurable number of unsafe confirmations and then runs:

```bash
display_disable enable <built-in-display-id>
```

Default behavior:

- check interval: `10` seconds
- unsafe confirmations: `2`
- logging disabled by default

### Configuration

The installer creates:

```bash
~/.displaydisabler-watchdog.conf
```

Example:

```bash
BUILTIN_ID="1"
TRUSTED_EXTERNAL_NAMES="DELL U2720Q|LG HDR 4K|Q27G4"
SUSPICIOUS_DISPLAY_NAMES="Display|Unknown Display"
CHECK_CONFIRMATIONS="2"
ENABLE_LOGGING="0"
DEBUG_LOGGING="0"
MAX_LOG_SIZE_KB="1024"
```

`TRUSTED_EXTERNAL_NAMES` contains external display names that are considered safe while the built-in display is disabled.

`SUSPICIOUS_DISPLAY_NAMES` contains generic or fallback display names that may appear after a disconnect event.

### Using multiple external monitors

If you use different monitors at home, at work, or through different docks, connect the new monitor and run:

```bash
trust-displays
```

This adds the currently connected stable external display names to:

```bash
~/.displaydisabler-watchdog.conf
```

Example:

```bash
TRUSTED_EXTERNAL_NAMES="Q27G4|DELL U2720Q|Studio Display"
```

Displays named `Display` or `Unknown Display` are not added automatically because those names are treated as suspicious fallback names.

### Logs and retention

Logging is disabled by default.

If lightweight logging is enabled, logs are written to:

```bash
~/Library/Logs/displaydisabler-watchdog.log
```

The watchdog rotates the log when it reaches `MAX_LOG_SIZE_KB`.

Default:

```bash
MAX_LOG_SIZE_KB="1024"
```

One rotated backup is kept:

```bash
~/Library/Logs/displaydisabler-watchdog.log.1
```

`DEBUG_LOGGING="0"` keeps the log lightweight.

Set:

```bash
DEBUG_LOGGING="1"
```

only when troubleshooting, because it writes full command output from `display_disable` and `system_profiler`.

### Uninstall

Run:

```bash
./scripts/uninstall_smart.sh
```

The uninstaller removes:

- the LaunchAgent
- the old LaunchAgent name, if present
- the watchdog script
- the old watchdog script name, if present
- the trust-displays helper
- the watchdog configuration file
- the watchdog state file
- aliases from `~/.zshrc`
- optionally the watchdog log file
- `/usr/local/bin/display_disable`

### Files added by this fork

```text
scripts/
├── install_smart.sh
├── uninstall_smart.sh
├── auto_enable_builtin_on_external_disconnect.sh
└── trust_current_external_displays.sh
```

User-level files created by the smart installer:

```text
~/.displaydisabler-watchdog.conf
~/Scripts/DisplayDisabler-Watchdog
~/Scripts/trust_current_external_displays.sh
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
~/Library/Logs/displaydisabler-watchdog.log
```
