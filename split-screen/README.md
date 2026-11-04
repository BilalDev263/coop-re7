# Two players on one PC (split screen)

Play coop-re7 with two players on **one** PC: two copies of RE7 run side by side, each player has their own
controller, and each plays on their own screen (or on half of one). The two copies talk over 127.0.0.1 with the
mod's `udp` mode, so no second Steam account and no internet connection between them are needed.

**Status:** tested on one PC (laptop, RTX 3050 Laptop 4 GB, 16 GB RAM, Windows 11, Steam build 22773795, coop-re7
v0.25, two DualSense pads through DS4Windows). Two players played the start of a new game together, about
10 minutes, each copy sending and receiving the whole time; then again with one player per screen. Saving with
player 1 then Continue on both is **not tested yet**.

## What you need

- RE7 on Steam, coop-re7 installed with `Install.cmd` (the co-op folder), Steam running.
- Two controllers that Windows sees as **XInput** pads 0 and 1: two Xbox pads, or PlayStation pads through
  DS4Windows (keep it running) or Steam Input.
- Two screens for the default layout (or `-Layout split` for top and bottom of one screen).
- The co-op folder on an **NTFS** drive: each player gets a folder of hardlinks to it (no extra disk), and exFAT or
  FAT32 drives have no hardlinks.
- Enough memory: each copy used about 8 GB of RAM. Close other programs, and keep graphics low.

## Set up (once)

1. Install coop-re7 as usual (`Install.cmd`).
2. Double-click **`Split screen setup.cmd`** in the coop-re7 folder. It downloads Couchlink's input hook (pinned
   release, SHA-256 checked), copies the launcher next to the co-op folder (`<co-op folder>-players`) and puts
   **RE7 Co-op split screen** on the desktop.

## Play

1. Start Steam (and DS4Windows for PlayStation pads).
2. Double-click **RE7 Co-op split screen**. Player 1 starts on the main screen with controller 1; once its co-op
   mod runs, player 2 starts on the other screen with controller 2. Both windows are borderless and stay that way.
3. Each player picks **New Game** (or **Continue**) with their own controller. The co-op status line says
   "connected" once both are in game.
4. Close both games to stop.

**Saving:** only player 1 saves (tape recorders and autosaves). Both copies run under one Steam account, so they
share one save folder and would overwrite each other. Next time, both pick **Continue** and load player 1's save.
The mod still backs your saves up at every start. `-NoSave` blocks saving for both.

Options (add them to the shortcut's command line): `-Layout split`, `-Pads 1,0` (swap controllers), `-NoSave`,
`-Rebuild` (after updating coop-re7). See the top of `Start-RE7-SplitScreen.ps1`.

## How it works

- **Network:** coop-re7's `udp` mode on 127.0.0.1, ports 27777 and 27778. With both copies on one Steam account
  the "lower SteamID hosts enemies" rule can't decide, so in `udp` mode the copy with the lower local port runs the
  enemies. `udp` mode now gets the same features as `steam` mode (held weapon, lobby look, enemy hand-offs, pause
  hand-off, catch-up list, health, heal my friend).
- **Controllers:** [Couchlink](https://github.com/cranebeaker/couchlink)'s input hook (MIT), loaded as a stand-in
  `xinput1_3.dll` with a config file (`COUCHLINK_HOOK_CONFIG`): XInput pad N is the copy's pad 0, every real pad is
  hidden from DirectInput, Raw Input and HID (`own_pads: []`; RE7 also reads PlayStation pads directly, and without
  this one pad drove both copies), fake focus so the copy in the background keeps running, and every named mutex
  renamed per copy.
- **Windows:** the launcher touches a window only after that copy's mod has started. Restyling or moving a copy's
  window while REFramework suspends the game's threads to install its hooks froze the game. That is also why
  Couchlink's own launcher did not work here: the second copy it started stalled before its first frame in 6 of
  7 runs, while the same hook with the same settings, started by this script, starts every time.
