# Orb Module Dev

Use this skill to create a distributable `.orbmodule` package for Orb. The skill is a development guide only. Do not copy it into the module package, and do not make Orb depend on it at runtime.

## Package Shape

```text
FeatureName.orbmodule/
  module.json
  bin/
    main
  Resources/
```

## Manifest Rules

- `manifestVersion` must be `1`.
- `id` must be globally unique, reverse-DNS style.
- `name` and `desc` are the only user-facing text Orb needs for the module list.
- `icon.symbol` is an SF Symbol name.
- `icon.gradient` contains two hex colors.
- `runtime.kind` is `executable` for third-party modules.
- `runtime.executable` points to the executable relative to the package root.
- Do not include agent prompts, private keys, or development notes in `module.json`.

## Executable Protocol

Orb invokes the executable from the module package root.

```sh
bin/main start
bin/main stop
bin/main status
bin/main action <command>
bin/main settings get
bin/main settings set <key> <value>
```

Environment variables:

- `ORB_MODULE_ID`
- `ORB_MODULE_PATH`

## Development Checklist

1. Create the `.orbmodule` directory.
2. Write `module.json`.
3. Add `bin/main` and make it executable.
4. Keep runtime assets under `Resources/`.
5. Install by copying the package into `~/Library/Application Support/Orb/Modules/`.
6. Toggle the module in Orb and verify `start` and `stop` run cleanly.
