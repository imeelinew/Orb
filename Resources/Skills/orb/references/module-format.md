# Orb Module Format

Read this when creating, reviewing, or debugging `.orbmodule` packages.

## Package Shape

```text
FeatureName.orbmodule/
  module.json
  bin/
    main
  Resources/
```

`SKILL.md` files, agent prompts, and development notes do not belong inside the package.

The package directory name is a technical name and must stay ASCII-only, for example `CommandLine.orbmodule`. The name shown as the Orb sidebar/module case comes from manifest `name`; it may be localized and does not need to match the package directory.

Finished modules should be written under `$HOME/Documents/Orb Modules/`, for example:

```text
~/Documents/Orb Modules/FeatureName.orbmodule/
```

When delivering a module, tell the user the exact path.

## Manifest

Minimal executable module:

```json
{
  "manifestVersion": 1,
  "id": "com.example.orb.feature",
  "name": "Feature Name",
  "desc": "Short user-facing description.",
  "version": "1.0.0",
  "displayOrder": 100,
  "icon": {
    "symbol": "terminal.fill",
    "gradient": ["#4F8BFF", "#7C5CFF"]
  },
  "runtime": {
    "kind": "executable",
    "executable": "bin/main"
  },
  "defaultEnabled": false,
  "permissions": ["filesystem"],
  "capabilities": [
    {
      "id": "open",
      "name": "Open",
      "desc": "Open the configured application.",
      "kind": "action",
      "command": "open"
    }
  ],
  "settings": [
    {
      "key": "appName",
      "title": "App Name",
      "desc": "Application name shown in the command row.",
      "type": "string",
      "defaultValue": "Visual Studio Code"
    }
  ]
}
```

## Manifest Rules

- `manifestVersion` must be `1`.
- `id` must be globally unique and reverse-DNS style.
- `name` and `desc` are the main user-facing text in Orb's module list.
- If the user has not provided the user-facing case name, ask for it before creating the module. Do not infer localized display text from the package filename.
- `icon.symbol` is an SF Symbol name.
- `icon.gradient` contains two hex colors.
- `runtime.kind` is `executable` for third-party modules.
- `runtime.executable` points to an executable relative to the package root.
- `defaultEnabled` should usually be `false` for distributed third-party modules.
- `displayOrder` controls ordering after built-in modules.
- `permissions` should be honest but concise.
- `capabilities` define callable actions Orb can expose. Each capability item should include a concise `desc` when the action name alone is not self-explanatory.
- `settings` define simple user-editable values Orb can store and pass through the executable protocol. Each setting item may include a concise `desc`, which Orb shows under the setting title in the module detail view.
- Use `type: "command"` for command reminders that should render as toggle rows in a module detail view, for example `orb cursor`.
- Do not use normal module detail UI for debug metadata such as executable status strings or package paths. Keep those for logs or diagnostics.

## Executable Protocol

Orb invokes the executable from the package root.

```sh
bin/main start
bin/main stop
bin/main status
bin/main action <command>
bin/main settings get <key>
bin/main settings set <key> <value>
```

Expected behavior:

- `start`: initialize background resources if needed, then exit successfully.
- `stop`: clean up background resources if needed, then exit successfully.
- `status`: print a short status string such as `ready`.
- `action <command>`: execute a capability command from the manifest.
- `settings get <key>`: print the current setting value.
- `settings set <key> <value>`: persist the value outside the package or in Orb-managed state when supported.

Environment variables:

- `ORB_MODULE_ID`
- `ORB_MODULE_PATH`
- `ORB_MODULE_ICON_SYMBOL` — SF Symbol name from the module manifest `icon.symbol`
- `ORB_MODULE_ICON_GRADIENT` — JSON array of hex color strings from the module manifest `icon.gradient`
- `ORB_POPOVER_EVENT_FILE` — path to a file that triggers a menu bar popover when written to. The file is watched by Orb; write the notification format below to show a popover from the menu bar icon.

### Menu Bar Popover

Modules can show a notification popover from the Orb menu bar icon by writing to the file at `ORB_POPOVER_EVENT_FILE`. The popover auto-dismisses after 5 seconds.

Minimal format (4 lines):

```
<kind>
<actionID>
<title>
<subtitle>
```

Full format with module icon (7 lines):

```
<kind>
<actionID>
<title>
<subtitle>
<iconSymbol>
<gradientStartHex>
<gradientEndHex>
```

- `kind`: `success` or `error`
- `actionID`: short identifier for the action (e.g. `copypath`)
- `title`: main title text
- `subtitle`: detail text
- `iconSymbol`: SF Symbol name (from `ORB_MODULE_ICON_SYMBOL`)
- `gradientStartHex`: start color of the circular icon gradient (from `ORB_MODULE_ICON_GRADIENT` array)
- `gradientEndHex`: end color of the circular icon gradient (from `ORB_MODULE_ICON_GRADIENT` array)

When `ORB_POPOVER_EVENT_FILE` is not set (e.g. when running outside Orb), the well-known fallback path is:

```
~/Library/Application Scripts/com.eli.Orb.FinderSync/popover-event.txt
```

Example usage in a module script:

```sh
popover_file="${ORB_POPOVER_EVENT_FILE:-$HOME/Library/Application Scripts/com.eli.Orb.FinderSync/popover-event.txt}"
if [ -d "$(dirname "$popover_file")" ]; then
  icon_symbol="${ORB_MODULE_ICON_SYMBOL:-questionmark}"
  gradient_json="${ORB_MODULE_ICON_GRADIENT:-[\"#4F8BFF\",\"#7C5CFF\"]}"
  gradient_start=$(printf '%s' "$gradient_json" | python3 -c "import sys,json;print(json.load(sys.stdin)[0])" 2>/dev/null || echo "#4F8BFF")
  gradient_end=$(printf '%s' "$gradient_json" | python3 -c "import sys,json;print(json.load(sys.stdin)[1])" 2>/dev/null || echo "#7C5CFF")
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "success" "myaction" "My Module" "Done: $result" \
    "$icon_symbol" "$gradient_start" "$gradient_end" \
    > "$popover_file"
fi
```

## Installation

Install by copying the whole package directory from `$HOME/Documents/Orb Modules/`:

```sh
mkdir -p "$HOME/Library/Application Support/Orb/Modules"
cp -R "$HOME/Documents/Orb Modules/FeatureName.orbmodule" "$HOME/Library/Application Support/Orb/Modules/"
```

Then open Orb, go to `模块`, and toggle the module on.

## Validation Checklist

1. `python3 -m json.tool FeatureName.orbmodule/module.json`
2. `test -x FeatureName.orbmodule/bin/main`
3. `cd FeatureName.orbmodule && bin/main status`
4. `cd FeatureName.orbmodule && bin/main start`
5. `cd FeatureName.orbmodule && bin/main stop`
6. Install into the user Modules directory.
7. Confirm Orb lists the module on the `模块` page.
8. Toggle it on and confirm it appears in the sidebar when enabled.
