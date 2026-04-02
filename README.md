# MultiPaste Prototype

This is a lightweight macOS prototype for ten independent clipboard slots.

## Hotkeys

- `Control` + `1` through `0`: copy current selection into slot `1` through `10`
- `Control` + `Shift` + `1` through `0`: paste from slot `1` through `10`

`0` maps to slot `10`.

## How it works

When you trigger a copy hotkey, the app simulates `Command-C`, waits briefly for the target app to update the system clipboard, then stores the clipboard contents in the selected slot.

When you trigger a paste hotkey, the app restores that slot to the system clipboard and simulates `Command-V`.

## Permissions

The app needs macOS Accessibility permission so it can simulate `Command-C` and `Command-V`.

On first launch, macOS should prompt you to allow access for the built binary or terminal host that runs it.

## Run

```bash
./run.sh
```

The app runs as a small menu bar utility with an `MP` title. Use the menu bar item to pause hotkeys, clear stored slots, or quit.
