# Changelog

## v0.15 (2026-11-03)
First attempts at the remaining gaps; all untested in play, each with a way to see what happened in the logs:
- **Enemies flinch from your friend's hits**: the enemy's own hit reaction is requested when your friend's damage
  arrives (a bigger reaction for big hits).
- **Pushed objects** (experimental, option *Share pushed objects*): chairs, bottles and other loose props you
  knock around move in your friend's game too.
- **Joe's hands**: a few likely hand files are tried in turn until one loads.
- Weapon sounds: the log now records what each weapon you hold is made of, to build sound sharing on next.

## v0.14 (2026-11-03)
- **Your friend's weapon in their hand** (experimental, option *Show your friend's weapon*): the weapon your
  character holds is shown in your character's right hand on your friend's screen. Untested: tell us what you see.
- **Friend marker**: the nameplate shows how far away your friend is, and when they're off screen a pointer at
  the edge of the screen shows which way to turn (or "behind you").
- **Safer shared interactions**: saving (tape recorders), VHS tapes, phones and item boxes are never shared.
- Works together with v0.13 (only the weapon needs v0.14 on both sides).

## v0.13 (2026-11-03)
- **More of your friend's moves show**: every move RE7 plays on your body is now mirrored, not just blocking:
  anything on the upper-body and hand layers (weapon swings and shots if RE7 plays them there) and full-body
  moves such as climbing a ladder or interacting. Untested with weapons: tell us what you see.
- **A downed friend lies on the floor** on your screen until you revive them (instead of crouching).
- **Following into VHS tapes**: when your friend puts a tape in, your game follows them into it a few seconds
  later (option *Follow my friend into VHS tapes*, on by default). It never jumps you back out; finish the tape.
- **Shared interactions** (experimental, option *Share interactions*, on by default): one-off actions like
  opening the fridge or the van, stirring the pot, long-press actions and switches happen in both games.
- **Key and weapon pickups**: when your friend picks one up, you're told to pick it up too (it stays for you, so
  your own story moments still happen).
- **Jack's scripted moments** (smashing through a wall) are shared along with cutscenes when *Share story* is on
  and you're close together.
- Both players need v0.13 (the movement update changed again).

## v0.12 (after the first two-player session, 2026-11-02)
- **Lobby**: see both players and their chapters, and pick how you look to your friend: Ethan, Mia, Mia (ship),
  Clancy, Zoe, Chris, Joe. Works with RE7's own models; with the Nexus mod "Third Person Full Model
  Placeholders" set up by **Use full models.cmd**, they're complete characters (your own view stays normal).
- **Blocking shows**: your friend's character blocks when they do (and plays the other upper-body moves RE7 puts
  on the player's body, like touching a door), on top of walking. Both players need v0.12.
- **Enemy hand-offs work between two real games**: both games now send enemy movement (before, only one
  did, so an enemy handed to the other player was taken back after 3 seconds: Jack flickered and only chased
  one player).
- **Doors close for both**, not just open. **Breakable boxes** and **drawers** are shared (new, untested).
- **Pausing**: your enemies are handed to your friend while you're paused, and they see "Your friend paused
  the game".
- **Weapons stay for both players** (picking one up froze the other player mid-pickup).
- **Share story reworked and off by default** (experimental): a friend's cutscene only pulls you in when you're in
  the same chapter and within about 12 m; story progress is only copied for 30 seconds after a cutscene you
  shared. (It used to push the player who was behind: a tape ended early, a chapter change got stuck.)
- Fixes: friend sliding after a tape; friend vanishing after the basement ladder (a background story event
  counted as a cutscene); stuck pause menu after a cut-short cutscene; Jack bouncing between games; save
  guard briefly blocking saves when the settings file was read mid-write; installer avoids OneDrive folders.
- Testing: bot buttons to smash the nearest box and open/shut the nearest drawer.
- **Make a bug report** button: a zip of the logs on your desktop, personal details blanked out.
- Logs are written once a second instead of on every line (less stutter late in a session); no more pile of
  coop_dummy_log_HHMMSS files (the previous run is kept as coop_dummy_log_prev.txt).
- **Reload last save** refuses after a chapter jump (it hung on the loading icon); restart and Continue instead.
- Enemy copies hold the same weapon as the original.

## v0.11 (2026-10-31)
- **Saving together**: when one player's game saves (tape recorder or autosave, with Allow saving on), the other
  sees "Your friend saved..." (and is told if their own saving is off), so you can both keep matching saves.
- **Safer saves**: enemies your game is copying from your friend's get their own AI back while a save is being
  prepared, so a save can't store them frozen. Following resumes a few seconds later.
- Not yet tested with a real save (only the notice, with a simulated friend).

## v0.10 (2026-10-31)
- **Downed and revive**: with your friend connected, a fatal hit puts you down instead of ending your game. You
  crouch, can't move, and the screen goes black and white, with a 90-second countdown. Your friend sees "Your
  friend is down!" with the distance; when they stand next to you for 3 seconds you get back up with 35% health.
  Both down, or nobody coming in 90 seconds, is a normal game over. Playing alone, nothing changes.
- Testing: "Take a fatal hit" button; the follow-me bot can revive you.

## v0.9 (2026-10-31)
- **Shared story** (early): when one player reaches a story cutscene, the other player's game plays the same
  one (started by name; you're pulled into the scene wherever you are). Story progress and finished story
  events are copied, and progress only ever moves forward. Each cutscene plays once per side; the list of
  played cutscenes survives script resets, so a finished scene is never replayed.
- **Share story** switch in the RE7 Co-op window (on by default) to turn it off.
- Testing: the bot can trigger the next story cutscene in your area.

## v0.8 (2026-10-31)
- **Shared doors**: a door unlocked in one game (with a key, or a one-way door from the other side) unlocks in
  the other; a door pushed open swings open on the other player's screen too.
- **Shared supplies**: ammo, healing items, crafting materials and weapons picked up by one player disappear
  from the other player's world (also in areas they reach later). Keys, files and maps stay in both worlds, so
  nobody gets stuck without a key.
- Testing: the bot can open the nearest door, unlock the nearest locked door, or take the nearest supply.

## v0.7 (2026-10-31)
- **Enemy movement** (early): each enemy is run by the game of the player nearest to it; the other game turns
  that enemy's own AI off and has it follow the running game (position and animation, 10 updates a second).
  When the other player gets clearly closer (3 m), the enemy is handed over, so enemies always chase a real
  player and their hits land on the right person. If the other game goes quiet, enemies come back after 3 s.
- **Fixed: your friend could disappear for good after they restarted their game** (their clock restarted and
  every update looked stale). Same fix for enemy updates.
- Fixed: your friend's Ethan could get stuck hidden, or visible but frozen without a nameplate, after a
  cutscene or a rebuild during loading.
- **Bot**: new "follow me" mode (walks your path, waits near you, copies your stance); "stay here" mode.
- **Testing**: fast-forward cutscenes (8x); record an enemy and replay it with its AI off; hand an enemy to
  the bot and back.

## v0.6 (2026-10-31)
- **Shared enemy damage and deaths** (first step of enemy sync). When you hurt an enemy, it loses the same
  health in your friend's game; when you kill it (or knock Jack down), it goes down there too. A regular
  enemy your friend killed in an area you haven't reached yet is already dead when you get there. Only
  between players in the same chapter.
- These events use Steam's guaranteed delivery, so a kill can't get lost.
- On screen: "Enemies: your friend took down ..." for a few seconds.
- Testing: the bot can hit or take down the enemy nearest to you.
- Not yet: enemies still move separately in each game, and hits don't make them flinch on the other screen.

## v0.5 (2026-10-31)
- **Footsteps**: you hear your friend's footsteps where they walk, using RE7's own walk, jog and crouch
  sounds. Switch off with **Friend's footsteps** in the RE7 Co-op window.
- **Installer**: warns when RE7 is on the older non-RT version (Steam beta `dx11_non-rt`), which is untested;
  its closing steps now describe the friend list.
- Checked: Steam names in Russian, Chinese, Japanese and Korean already show correctly on the nameplate and
  in the friend list.

## v0.4 (2026-10-31)
- **Pick your friend from a list**: the RE7 Co-op window lists your Steam friends who are running RE7 Co-op,
  each with a **Connect** button. No more copying SteamIDs (still possible under *Connect with a SteamID
  instead*).
- **Invites**: connecting to a friend shows them "*<name>* invited you to co-op" on screen; they click
  **Accept**. Uses Steam rich presence, so nothing else needs setting up.
- **Go to my friend's chapter**: jumps to the start of your friend's chapter (saving is switched off first).
  Chapter names are shown instead of numbers.
- **Teleport to my friend** now lands on ground your friend walked on, and only within 40 m (RE7 only loads
  the area around you, so long warps could land outside the map).
- The friend list warns when your friend runs a different coop-re7 version.
- Fixed: a script error while a chapter was loading. Testing: the bot can pretend to be in another chapter.

## v0.3 (2026-10-29)
- **One-click installer** (`Install.cmd`): finds RE7 in Steam, copies it to a co-op folder, downloads
  REFramework + C# add-on from the official release with SHA-256 checks, installs the mod, backs up saves,
  creates a desktop shortcut. Re-running it updates the mod and keeps your settings.
- **Allow saving** switch (off by default) with automatic save backups at every launch and on demand; the
  newest 20 are kept.
- **On-screen status** in the top-left: connection, friend's name, ping, "friend is in another chapter",
  version-mismatch warning, saving state.
- **Nameplate** with your friend's Steam name over their Ethan.
- **Teleport to my friend** button.
- **RE7 Co-op window**: a floating window (opens with the REFramework menu) with Connect, saving and display
  options, and a Testing section.
- **Chapter switcher** (Testing): jump to any chapter with RE7's own chapter jump. Saving is switched off first
  so a test jump is never saved. Starting together in the same chapter is the easiest way to meet up.
- Fixed: the ghost could separate from its position while crouching (the crouch idle clip jammed the
  animation, and a blend was mistaken for an error).
- Fixed: head look stopped working after Rebuild Ethan.
- Bot: follows you to new chapters and after loads or teleports.
- **Save protection fix:** with saving off, chapter jumps could still write your save files through internal
  save paths. These are now blocked too (verified: save files unchanged across a chapter jump). If you used
  an earlier test build's chapter switcher, restore your saves from the backup the installer made.
- The co-op ghost also works in sections played as other characters (e.g. the videotapes).
- The other player is hidden while you watch a cutscene, and while they watch one (shown as "Friend is
  watching a cutscene").
- Chapter switcher allows one jump at a time (rapid jumps could leave cutscenes invisible and you outside
  the map). Collision never pushes you during cutscenes or loads.
- The packet now carries the chapter and a round-trip echo, used for the ping (the format is unchanged in size,
  but v0.2 and v0.3 players won't understand each other's chapter and ping).

## v0.2 (2026-10-29)
- Ethan builds himself automatically. Walk, jog and crouch in four directions, idle, head look, smoothed turns
  and blends.
- Can't walk through the other player.
- Ghost rebuilds after save loads, deaths and area changes, and hides when the other player's data stops.
- In-game **Connect** panel (copy your SteamID, paste your friend's).

## v0.1 (2026-10-29)
- First prototype: the other player as a ghost body over Steam relay.
