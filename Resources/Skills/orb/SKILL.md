---
name: orb
description: Work on the Orb macOS app and its modular runtime. Use when Codex needs to create, inspect, install, test, or modify Orb `.orbmodule` packages; update Orb's module host, sidebar/module UI, native modules, executable-module protocol, FinderSync/menu-bar/window/input features, or an Orb app codebase.
---

# Orb

Use this skill for Orb app work and Orb module development. Treat the live repository, app behavior, screenshots, and tests as the source of truth.

## Core Rules

- Keep the `skill` separate from runtime modules. A skill is only a development guide for agents; never copy it into an `.orbmodule`, and never make Orb depend on Codex skills at runtime.
- A finished `.orbmodule` must be usable without an agent. The module may call tools, CLIs, apps, or models, but its runtime entrypoint must stand alone.
- The app-bundled copy of the `orb` skill is the source of truth. The installed Codex skill path should point to `Orb.app/Contents/Resources/Skills/orb` by symlink.
- Preserve the app-window invariant: cold launch and Dock re-open must show the main window immediately.
- Preserve user-provided UI text exactly. Do not invent module descriptions, labels, or extra explanatory UI copy without permission.
- Keep module package names and technical identifiers ASCII-only. The package directory name and the Orb-visible case name are separate; the visible case name comes from the manifest `name`.
- Prefer the existing Orb patterns in the current Orb repository before adding new abstractions.

## Workflow

1. Inspect current state first:
   - `git status --short --branch -uall`
   - relevant files under the current Orb repository
   - installed/runtime behavior when the user reports UI or app-launch issues
2. For Orb app changes, keep edits scoped to the requested module/UI/runtime surface.
3. For `.orbmodule` package work, read `references/module-format.md` before writing manifests or executable entrypoints.
4. Put finished `.orbmodule` packages in `$HOME/Documents/`. Do not leave finished modules inside the Orb repository unless the user explicitly asks for a repo example.
5. Tell the user the exact module output path in the final response.
6. Install third-party modules by placing the whole package directory in:
   - `~/Library/Application Support/Orb/Modules/`
7. Verify every meaningful change with the narrowest reliable checks, usually:
   - `git diff --check`
   - `xcodebuild test -project Orb.xcodeproj -scheme Orb -destination 'platform=macOS' -only-testing:OrbTests -derivedDataPath /tmp/orb-skill-derived-data`
   - `python3 -m json.tool <module.json>`
   - `plutil -lint Config/Orb-Info.plist` when Info.plist changes
8. If creating a distributable module, also run its executable protocol manually:
   - `bin/main status`
   - `bin/main start`
   - `bin/main stop`
   - `bin/main action <command>` when actions exist

## Orb Module Mental Model

- Built-in modules are native modules shipped with Orb, currently represented as bundled `.orbmodule` manifests.
- Third-party modules are hot-pluggable `.orbmodule` packages loaded from the user Modules directory.
- Module enablement controls whether the module appears in the sidebar and whether its runtime is active.
- Disabled modules must remain visible in the main `模块` page so the user can turn them back on.
- A module's visible identity is: name, desc, SF Symbol, gradient, capabilities, and settings.

## Common Paths

- App repo: the current Orb repository
- Module host: `Orb/OrbModuleHost.swift`
- Module model: `Orb/OrbModule.swift`
- Settings UI: `Orb/OrbView.swift`
- App lifecycle: `Orb/AppDelegate.swift`
- Bundled modules: `Resources/Modules/`
- Finished module output: `$HOME/Documents/`
- User-installed modules: `~/Library/Application Support/Orb/Modules/`

## When Editing Orb UI

- Keep the standalone `模块` case first in the sidebar.
- Keep enabled built-in modules under the sidebar section title `内置模块`.
- Keep enabled user-installed modules under the sidebar section title `自定义模块`.
- Turning off a module removes that case from the sidebar.
- The module page shows each module with icon, name, desc, and a right-side toggle.
- Installing or uninstalling a module should show a toast only after the module actually installs or uninstalls successfully.
- Module enablement belongs only on the standalone `模块` page. Do not put module on/off toggles inside an individual module detail view.
- Do not show developer/debug metadata such as executable status strings or package paths in normal module detail UI unless the user explicitly asks for diagnostics.
- Individual module detail views should expose only meaningful user-facing controls, capabilities, or settings from that module.
- Keep list rows visually calm and native; do not add explanatory text beyond approved names/descriptions.

## When Creating Modules

- If the user has not explicitly provided the Orb-visible case name, ask: `你想给这个模块显示什么名字？` This asks for the case name shown in Orb, not the package filename.
- Use an ASCII technical package directory name, for example `CommandLine.orbmodule`. Do not use Chinese or other localized display text in the package directory name.
- Store the user-approved case name in manifest `name`. The manifest `name` may be localized, and it does not need to match the package directory name.
- Use module settings or capabilities to surface memorable user actions. Each user-facing item can include a concise manifest `desc`; Orb shows setting descriptions under the item title in the module detail view.
- For example, a command-line module should show entries such as `orb cursor` and `orb vscode` directly in Orb, with per-item `desc` values when the command name needs context.
- Use reverse-DNS IDs, for example `com.example.orb.open-vscode`.
- Write finished module packages under `$HOME/Documents/`, for example `~/Documents/CommandLine.orbmodule`.
- In the final response, state the exact module path.
- Use `runtime.kind: "executable"` for third-party modules unless changing Orb native code too.
- Keep all runtime assets inside the `.orbmodule` package.
- Store private keys, local secrets, and user-specific state outside the package.
- Make scripts executable with `chmod +x`.
- Prefer simple CLI protocols over hidden background assumptions.
