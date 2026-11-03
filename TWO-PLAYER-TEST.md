# coop-re7: two-player session checklist

Everything in coop-re7 has so far been tested on one PC against a simulated player (the bot). This list walks
two real players through every shared feature once, so problems show up in a known order. It takes about
45 minutes. Tick things off as you go and note anything odd (what you saw, roughly when).

**Before you start (both players)**

- [ ] Both installed the same coop-re7 release (the friend list warns if your versions differ).
- [ ] *Allow saving*: off by default (nothing kept). To keep your progress, both tick it before playing.
- [ ] A player starting RE7 for the first time plays the opening alone first (joining during it leaves a black
      screen), then connects.
- [ ] Voice chat open (Discord or Steam) so you can say what you see.

## 1. Connect (5 min)

- [ ] Both start **Start RE7 Co-op** and load any save.
- [ ] Each sees the other under *Your Steam friends in RE7 Co-op*.
- [ ] Player A clicks **Connect** next to Player B. Player B sees "*A* invited you to co-op" at the top left.
- [ ] Player B presses Insert and clicks **Accept**.
- [ ] Both see **Co-op: connected to *name* - *ping* ms** at the top left. Note the ping: ____ ms

## 2. Meet up in Chapter 3 (5 min)

- [ ] Both tick **Show developer tools**, open **Developer tools → Chapter switcher** and click **Chapter3**, once each. (Or: one player clicks it,
      the other uses **Go to my friend's chapter**.)
- [ ] Watch the dinner (fast-forward is fine) until you can both move.
- [ ] Each can see the other's Ethan, with their name above it. Walk, jog and crouch around each other.
- [ ] You hear each other's footsteps.
- [ ] You can't walk through each other.

## 3. Doors and items (5 min)

- [ ] Player A pushes a door open. It swings open on Player B's screen too.
- [ ] Player A picks up some ammo, a herb or a chemical. It disappears from Player B's world.
- [ ] A key item, file or map stays for both (each picks up their own).

## 4. Enemies (10 min)

Jack appears soon after dinner. Saving is off, so getting hurt costs nothing.

- [ ] Both see Jack in the same place, doing the same thing.
- [ ] Shooting Jack on one screen lowers his health on the other (the RE7 Co-op window, *Developer tools*, shows
      "Enemy sync" with his health).
- [ ] Knocking Jack down on one screen knocks him down on the other.
- [ ] Walk away from Jack while your friend stays near him. He should keep chasing the nearer player
      (enemies change hands when the other player is 3 m closer).

## 5. Going down and reviving (5 min)

- [ ] Let Jack hit Player A until a fatal hit. Player A goes **down** (crouched, black and white, can't move)
      instead of a game over. Player B sees "Your friend is down!" with the distance.
- [ ] Player B stands next to Player A for 3 seconds. Player A gets back up.
- [ ] (Optional) Both get downed at once: that should be a normal game over for both.

## 6. Story (10 min)

- [ ] Follow the objective until a story cutscene starts for one of you. The other player's game should play
      the same cutscene (they're pulled into the scene).
- [ ] After it, both carry on normally. If someone is stuck and can't move, restart the game (nothing was
      saved) and note which cutscene it was.

## 7. Leaving (2 min)

- [ ] Player B closes the game. Player A's view of B disappears within a few seconds; enemies B was running
      come back to Player A within 3 seconds.
- [ ] Player B starts again and reconnects. A sees B again.

## 8. New since the first session (v0.12-v0.19), in the order you'll meet them

Playing from the start of the game. Note for each: works / doesn't / looks odd.

- [ ] **Talk** (new): A presses **F6** (Come here). B sees "Your friend: Come here (*n* m)" at the top of the
      screen and a marker where A stood. Try **F5** (ping), **F7** (wait), **F8** (help).
- [ ] **Health** (new): the status line and nameplate show the other player's health (green, yellow, red).
- [ ] **Lobby**: each picks a character; the other sees the change within a few seconds.
- [ ] **Doors**: A opens a door and lets it close; it opens and closes on B's screen too.
- [ ] **Interactions**: A opens the van or the fridge, stirs the pot, flips a switch. Does it happen for B?
- [ ] **Drawers and boxes**: A opens a drawer; A smashes a breakable box. On B's screen the box disappears and
      its item lies where it stood. **Both** can pick up an item from it.
- [ ] **Pushed objects**: A knocks a chair or bottle around. Does it move for B?
- [ ] **Supplies**: A picks up ammo. It stays for B (each gets their own). Then both tick **Share supplies**
      (Options) and A picks up another: now it disappears for B. A walks into another area and back: B's other
      supplies must still be there.
- [ ] **Keys**: A picks up a key. B is told to pick it up too, and it's still there for B.
- [ ] **VHS tape**: A puts a tape in (B nearby). B's game follows into the tape a few seconds later.
- [ ] **Moves**: A blocks, swings the knife, aims and shoots the handgun, climbs a ladder. Which does B see?
      (Gunshot sound and muzzle flash aren't expected yet.)
- [ ] **Enemies**: A hits Jack or a Molded. On B's screen it loses health and flinches. Walk closer to it one at
      a time: it should keep moving smoothly and go after the nearer player.
- [ ] **Pausing**: A pauses near an enemy. B sees "Your friend paused the game"; the enemy keeps moving for B.
- [ ] **Downed**: A takes a fatal hit and lies on the floor; B walks over and A gets up.
- [ ] **Garage fight (boss mode)**: each player gets the whole fight in their own game. Jack's hits by one player
      count for both, and when he goes down for one, he goes down for both.
- [ ] **Rejoin catch-up** (new): B quits the game while A carries on (unlock a door, smash a box, take a herb).
      B starts again and reconnects. Within a few seconds B sees "Caught up with *n* changes from your friend",
      and A's changes are there in B's world.

## Afterwards

Each player clicks **Make a bug report** (RE7 Co-op window, *Help*) and sends the zip
it puts on their desktop. SteamIDs and names are already blanked out.
