[Download MultiPaste for Mac](https://github.com/ishaan0x/MultiPaste/releases/latest/download/MultiPaste.zip) includes `MultiPaste.app` and `Open MultiPaste.command`.

# MultiPaste

MultiPaste is a lightweight macOS menu bar app for ten independent clipboard slots.

![MultiPaste overview](assets/multipaste-hero.svg)

## Hotkeys

- `Control` + `1` through `0`: copy current selection into slot `1` through `10`
- `Control` + `Shift` + `1` through `0`: paste from slot `1` through `10`
- `Control` + `Space`: open the casing picker
- `Control` + `L`: select the current browser address, copy it, and store it in the next open slot

While you hold `Control` + `Shift`, MultiPaste shows a temporary overlay with the currently filled slots, a short preview of each slot, and when it was last updated.

When you take a macOS screenshot with `Command` + `Shift` + `4`, MultiPaste watches your configured screenshot folder and stores that new screenshot in the next open slot automatically. If all ten slots are full, it leaves the screenshot alone.

When you press `Control` + `L`, MultiPaste simulates `Command` + `L` followed by `Command` + `C`, then stores the copied browser address in the next open slot. If all ten slots are full, it does nothing beyond showing `No open slot`.

Inside the casing picker:

- `Up` / `Down`: move between options
- `Return`: apply the highlighted option
- `N`, `L`, `U`, `T`, `S`: jump directly to `Normal`, `Lowercase`, `Uppercase`, `Title Case`, or `SpongeBob`
- `Escape`: cancel

`0` maps to slot `10`.

## How it works

When you trigger a copy hotkey, the app simulates `Command-C`, waits briefly for the target app to update the system clipboard, then stores the clipboard contents in the selected slot.

When you trigger a paste hotkey, the app restores that slot to the system clipboard and simulates `Command-V`. While `Control` + `Shift` is held, you also get a temporary overlay showing only the filled slots and their recent contents.

When you trigger the casing picker, the app copies the current selection, lets you choose a casing transform from a small popup, then pastes the transformed text back, reselects that transformed text, and restores your previous clipboard contents. `Normal` uses sentence-case heuristics, and SpongeBob casing uses a deterministic seeded pattern with about 42% uppercase letters on average.

The menu bar menu also lets you clear any individual filled slot or clear all slots at once.

## Permissions

The app needs macOS Accessibility permission so it can simulate `Command-C` and `Command-V`.

On first launch, macOS should prompt you to allow access for the built binary or terminal host that runs it.

## Install

### Download the app

Download [MultiPaste.zip](https://github.com/ishaan0x/MultiPaste/releases/latest/download/MultiPaste.zip). The ZIP includes `MultiPaste.app` and `Open MultiPaste.command`.

### First launch

1. Unzip `MultiPaste.zip`.
2. Drag `MultiPaste.app` into `Applications`.
3. Double-click `Open MultiPaste.command` from the unzipped folder.
4. Grant Accessibility access when macOS prompts, or enable `MultiPaste` manually in `System Settings` > `Privacy & Security` > `Accessibility`.

After that, MultiPaste should run as a menu bar app with an `MP` label.

## Build From Source

To build and run the local development version:

```bash
./run.sh
```

## Package a Downloadable App

To build a `.app` bundle and zip it for a GitHub release:

```bash
./scripts/package_app.sh 0.2.0
```

This creates:

- `dist/MultiPaste.app`
- `dist/Open MultiPaste.command`
- `dist/MultiPaste.zip`

The package script always signs the app bundle before zipping it. By default it
uses an ad-hoc signature so the archive has a valid bundle signature on every
machine. For Developer ID signing, set `MULTIPASTE_SIGNING_IDENTITY` before
running the script; set `MULTIPASTE_SIGNING_KEYCHAIN` too if the identity lives
outside the default keychain search path.

## Update Installed App

To update the already-installed app in `/Applications` without changing its path:

```bash
./scripts/package_app.sh 0.2.0
sudo ./scripts/install_app.sh
```

This replaces `/Applications/MultiPaste.app` in place and restarts the login-item copy if it is configured.

## GitHub Releases

This repo includes a GitHub Actions workflow at `.github/workflows/release.yml`.

- Push a tag like `v0.2.0` to upload `MultiPaste.zip` to that release.
- Or run the workflow manually from the Actions tab and enter a version.

The app is not notarized. The release ZIP includes `Open MultiPaste.command`,
which removes the download quarantine attribute from `MultiPaste.app` and opens
it. A Developer ID certificate plus Apple notarization is required to avoid that
first-launch workaround entirely.
