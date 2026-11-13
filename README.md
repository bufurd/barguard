# Bar Guard

A small addon for **WoW Forever** that remembers your action bars for each spec and puts them back if the dual-spec bug wipes them.

## What it does

- Keeps a snapshot of your action bars for each character and each spec: spells, items and macros (macros are matched by name and body), on slots 1-180.
- Checks your bars 4 seconds after you log in and after every spec switch. If 3 or more remembered slots are empty, it treats that as a wipe and puts the icons back.
- **It only fills empty slots.** It never overwrites an icon you placed yourself.
- It won't save over a good snapshot when your bars come up mostly empty, so a wipe can't replace your saved layout.

## Install

1. Download `BarGuard.zip` from the [latest release](https://github.com/bufurd/barguard/releases/latest/download/BarGuard.zip). Don't use GitHub's "Source code" zip.
2. Extract it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\BarGuard\BarGuard.toc`.
3. Restart the game, or reload with `/reload`.

## Commands

| Command | What it does |
|---|---|
| `/barguard` | Opens the options (Esc > Options > AddOns > Bar Guard) |
| `/barguard status` | Shows the current spec, the snapshot, and which spec API answered |
| `/barguard snap` | Saves your bars as they are right now |
| `/barguard restore` | Fills empty slots from the snapshot |
| `/barguard log` | Prints the recent diagnostic log |

`/bguard` works as a short alias.

## Options

- **Put wiped bars back automatically.** On by default. Turn it off and you only get a chat message, then you type `/barguard restore` yourself.
- **Ask first.** Off by default. Shows a Yes/No box before putting icons back.
- **Say so in chat.** On by default. Prints one line in chat when icons were put back.

## Reporting a problem

Please open an issue and include the output of `/barguard status` and `/barguard log`.

## Credits

Written by Bufurd and Claude (Anthropic).
