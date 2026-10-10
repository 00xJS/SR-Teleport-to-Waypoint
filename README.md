# Teleport to Waypoint

A mod for Saints Reborn ([Windows](https://github.com/whompay/SaintsReborn) /
[Mac](https://github.com/00xJS/SaintsReborn-Mac)), the Windows and Mac
version of the original Saints Row. Drop a waypoint on the map and you're
there. No more driving across Stilwater to get to the fun part.

## What it does

- **Point and go.** Open the map, put your waypoint down, and the map closes
  by itself as you arrive at the spot you picked.
- **Rooftops count.** You land on the highest thing at that point: a road, a
  rooftop, the top of the Ultor dome. Pick a building and you're on top of it.
- **Your ride comes with you.** Teleport from the driver's seat and the car
  arrives too. Your homies as well.
- **Your waypoint, not the game's.** Only the green waypoint you place
  triggers a jump. The blue mission marker never does, so a mission can't
  drag you somewhere you didn't choose.
- **8** jumps to your waypoint again without opening the map.
- **9** shows your position in the corner of the screen, if you like to
  know where you are (Windows build).

Works on both the Windows and the Mac build. Single player (and story co-op
as the host). In a multiplayer match the mod stays out of the way.

## Install

1. Download this repository (Code > Download ZIP) and unzip it.
2. Copy the `TeleportToWaypoint` folder into your mods folder:
   - **Windows** ([Saints Reborn](https://github.com/whompay/SaintsReborn)): `dist\mods\` inside your Saints Reborn folder
   - **Mac** ([Saints Reborn for Mac](https://github.com/00xJS/SaintsReborn-Mac)): `~/SaintsReborn/dist/mods/`
3. Start Whompay's Mod Loader, tick **Teleport to Waypoint**, press **Play**.

**Windows and Mac.** The teleport itself is a script and runs on both. The
F8 position readout is a small Windows add-on (`coords.dll`); on the Mac
build it simply doesn't load and everything else works the same.

Works alongside Saints Tweaks, More Homies, Living Stilwater and the trainer.
Private play only, like every gameplay mod. Contains no game files. Not made
by or connected to the Saints Reborn project, Volition or Deep Silver.

## Tips

- Waypoints only "take" where the game can draw a route, so put them near a
  road. A dot in the middle of the water or far out past the edge of the city
  stays put, and the mod tells you so.
- Click right on a building to land on its roof. Click the street to land on
  the street.
- The jump happens the moment the waypoint is accepted. If you only want the
  route drawn, the mod can be unticked in the loader and ticked again later.

## Keys

| Key | Does |
|---|---|
| **8** | Jump to your green waypoint |
| **9** | Position readout on / off (Windows) |

Both can be changed in `mod.ini` (`teleport_key`, `coords_key`) to any letter,
digit or F1–F12, or left blank for none. The defaults are number keys on
purpose: they work the same on Windows and on a Mac keyboard, where the
F-keys are brightness and volume unless you hold Fn. Keys 0–7 are used by
Saints Tweaks, so these two don't clash with it.

## Settings

Everything is in `TeleportToWaypoint\mod.ini` under `[settings]`. Restart the
game after changing them.

| Setting | Default | What it does |
|---|---|---|
| `teleport_on_map_waypoint` | true | Jump whenever you place a waypoint on the map |
| `teleport_key` | 8 | Key that jumps to your waypoint (blank for none) |
| `coords_key` | 9 | Key that toggles the position readout (blank for none) |
| `close_map` | true | Close the map by itself after a jump |
| `hud_messages` | true | Show "Teleported to the waypoint" on the HUD |
| `hud_seconds` | 3 | How long that note stays |
| `debug` | false | Write every step to `mods\wml.log`, if you want to report something |

## Credits

Built on Whompay's Mod Loader, which ships with Saints Reborn. MIT licensed;
see `LICENSE`.
