# Agent CLI Command Palette

**English** · [中文](README.md)

A dockable Windows sidebar that turns the flags and slash commands of AI coding CLIs into labelled buttons. Click one and the real command is typed into whichever terminal window you bound.

The palette itself understands nothing about the commands it sends. It does two things: type an item's text into the target terminal, or send its key combo. Swapping in a different `commands-*.json` therefore drives a different CLI without a line of code changing.

Four command tables ship with it:

| Table | CLI | Groups | Items |
|---|---|---|---|
| `commands-claude.json` | Claude Code | 7 | 60 |
| `commands-codex.json` | OpenAI Codex CLI | 8 | 61 |
| `commands-opencode.json` | OpenCode | 7 | 83 |
| `commands-pi.json` | pi | 8 | 97 |

The shipped tables are written in Chinese, since that is what the author reads. Everything user-facing lives in JSON, so translating a table is editing strings — no code involved.

## Why this exists

These CLIs keep their real power in dozens of flags and slash commands. `--dangerously-skip-permissions`, `-a untrusted`, `--sandbox workspace-write`, `/compact`, `/rewind` — few people remember them, and `--help` is too long to read at the moment you need it.

So every button carries a one-line explanation and the real command only appears on hover. You look for *what you want to do*, not for *what the flag is called*. The search box matches Chinese, English and pinyin initials.

## Quick start

1. Clone or download this repository.
2. Double-click `启动命令面板.cmd` ("start command palette").
3. Click **新开终端** (New terminal) to spawn one, or **绑定窗口** (Bind window) to pick a terminal that is already open.
4. Click any command.

Needs Windows 10/11 and the built-in Windows PowerShell 5.1. Nothing to install.

## Using it

**Bind a terminal first.** The palette has to know where to type. *New terminal* spawns one and binds it automatically; *Bind window* lists every visible window, with terminal-like processes tagged `[终端]` and sorted first.

**Left click types into the terminal, right click copies to the clipboard.** Right click is the way out when the target terminal runs elevated (see limitations).

**Three checkboxes:**

- *Auto-Enter after click* — run immediately. Off by default so you can fill in arguments first.
- *Always on top* — keep the palette above other windows.
- *Type character by character* — on by default, using `SendInput`. Uncheck it to paste via the clipboard instead: faster for long commands, but it overwrites your clipboard.

**Dock** snaps the palette to the left of the work area and moves the bound terminal into the space that is left.

**The profile button** switches CLI. Switching swaps the command table and the UI strings, and **deliberately leaves the bound terminal alone** — same window, different command set. The menu rescans the directory every time it opens, so dropping a new `commands-*.json` in while the palette is running is enough.

**Reload** re-reads the JSON without restarting the palette.

## Writing your own command table

Name the file `commands-<name>.json` and put it next to the script; `<name>` is what appears in the switcher. The file must be **UTF-8** (BOM optional).

```json
{
  "settings": { "sidebarWidth": 300, "insertMode": "type", "autoEnter": false,
                "topMost": false, "shell": "auto", "workDir": "" },
  "ui": { "title": "Agent CLI Command Palette", "btnBind": "Bind window" },
  "groups": [
    {
      "name": "Start / sessions",
      "items": [
        { "label": "Start interactive", "cmd": "mycli", "desc": "the one you use most", "tags": "start" },
        { "label": "Newline (key)", "keys": ["Ctrl+J"], "desc": "sends a key, types nothing", "tags": "newline" }
      ]
    }
  ]
}
```

Per item:

- `label` — the button text. Write it the way you would say it.
- `cmd` — the real command, shown only in the hover tooltip. Write `mycli ""` to leave the caret between the quotes.
- `keys` — alternative to `cmd`: send a key combo instead of text, e.g. `["Ctrl+Shift+F"]`, `["Escape", "Escape"]`. `Ctrl` / `Shift` / `Alt` / `Win` modifiers plus names like `Enter`, `Tab`, `Esc`, `F1`-`F12` and the arrow keys are understood.
- `desc` — the explanation shown on hover.
- `tags` — extra search keywords.

Any `ui` key you omit keeps the value already in use, so a new table can get away with just a `title` and its commands instead of rendering blank buttons.

## Command-line options

```powershell
# Start with a specific table
powershell -NoProfile -STA -File AgentCliPalette.ps1 -Config "commands-pi.json"

# Build the whole UI and run internal checks without showing the window
powershell -NoProfile -STA -File AgentCliPalette.ps1 -SelfTest

# Also spawn a real terminal and round-trip a command through it
powershell -NoProfile -STA -File AgentCliPalette.ps1 -SelfTest -Live

# Keep powershell.exe's own console on screen (troubleshooting)
powershell -NoProfile -STA -File AgentCliPalette.ps1 -KeepConsole
```

`-SelfTest` reports which tables were discovered, how many buttons rendered, what virtual-key codes each combo parses to, whether a profile switch round-trips cleanly, and where the tooltip flips at the screen edge. Run it after any change.

## Where the command tables come from

Not from memory. Every entry was checked against the version installed on this machine: the CLI's own `--help` first, then slash commands and keybindings grepped straight out of the installed executable or bundle.

That policy came from getting it wrong. The palette once claimed Claude Code's newline was Shift+Enter, while the app's own hint reads `ctrl+j for newline` — Shift+Enter needs `/terminal-setup` to write a terminal-specific binding first, and some terminals refuse outright.

For the same reason some things are **deliberately absent**:

- Codex's `/approvals`, `/limits`, `/undo` and friends could not be confirmed in the binary, so they were left out rather than guessed.
- OpenCode has **no keyboard-shortcut group**. Its TUI keybinding defaults are not greppable in the binary (the ones that are belong to the web/desktop UI, not the terminal), so none were invented.
- pi's shortcuts are the **Windows branch**. Its keymap contains tests like `windowsKeybindings ? "alt+v" : "ctrl+v"`, so on this platform pasting an image is Alt+V, queueing a follow-up is Ctrl+Q and the previous model is Alt+P — different from other platforms.

## Known limitations

- **Elevated terminals cannot receive keystrokes.** A normal-privilege process may not send input to a higher-privilege window; that is Windows UIPI isolation and there is no way around it. The palette raises a clear error instead of typing the command into itself. Use right-click-to-copy, or *New terminal* to get a terminal at matching privilege.
- **Windows only.** The whole thing rests on WPF plus user32's `SendInput` / `AttachThreadInput`.
- **One bound terminal per palette window.**
- With QQ Pinyin installed, the console may print `libpng warning: iCCP: cHRM chunk does not match sRGB`. That comes from the IME's DLL injecting into every GUI process; it has nothing to do with this project.

## Implementation constraints worth knowing

These are not accidents — change them and things break:

- **`AgentCliPalette.ps1` is ASCII-only on purpose.** Windows PowerShell 5.1 decodes BOM-less `.ps1` files using the system ANSI codepage, which turns embedded non-ASCII text into mojibake. All user-visible strings therefore live in JSON, read explicitly as UTF-8.
- **`.cmd` files must be CRLF.** `cmd.exe` mis-parses LF-only batch files. Pinned via `.gitattributes`.
- **The launcher deliberately avoids `-ExecutionPolicy Bypass` + `-WindowStyle Hidden`.** That pair is the classic antivirus signature for a PowerShell loader, and the AV on this machine deletes `.cmd` files that use it. So the launcher shows its console honestly and the script hides it once the palette window is up — which also means a startup failure stays readable on screen.
- **Never use `.GetNewClosure()` for event handlers.** A closure is hosted in its own dynamic module, so `$script:` assignments inside it never reach the enclosing script scope. Window binding once failed silently for exactly this reason.
