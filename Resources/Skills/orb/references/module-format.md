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

Finished modules should be written under `$HOME/Documents/`, for example:

```text
~/Documents/FeatureName.orbmodule/
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
      "kind": "action",
      "command": "open"
    }
  ],
  "settings": [
    {
      "key": "appName",
      "title": "App Name",
      "kind": "string",
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
- `capabilities` define callable actions Orb can expose.
- `settings` define simple user-editable values Orb can store and pass through the executable protocol.
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

## Installation

Install by copying the whole package directory from `$HOME/Documents/`:

```sh
mkdir -p "$HOME/Library/Application Support/Orb/Modules"
cp -R ~/Documents/FeatureName.orbmodule "$HOME/Library/Application Support/Orb/Modules/"
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
