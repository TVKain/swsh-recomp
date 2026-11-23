Pokemon Sword Recomp
====================

A native Windows port of Pokemon Sword (Nintendo Switch) made by static recompilation: the game's code is translated
and compiled for your PC. It is not an emulator. Fork with Intel Arc fixes, 60 fps battles and menus, XeSS and a
simpler setup: https://github.com/TVKain/swsh-recomp (based on https://github.com/raulzrrs/swsh-recomp).

NO GAME FILES OR KEYS ARE INCLUDED. You need your own legally obtained copy of Pokemon Sword, dumped from your own
Switch.

What you need
-------------
1. Your game files, any ONE of these:
   a. The packed files from your Switch (easiest):
        - the game: an .xci (cartridge dump) or the base game's .nsp (eShop)
        - the 1.3.2 update: an .nsp (title id 0100ABF008968800)
        - optional, the Expansion Pass: the two DLC .nsp files (Isle of Armor, Crown Tundra)
      plus your console keys: prod.keys, dumped from your own Switch (for example with Lockpick_RCM). If you use an
      emulator (Eden, Ryujinx, yuzu and its forks) the launcher finds its prod.keys by itself.
   b. Or a folder with the game already extracted with the 1.3.2 update applied (exefs and romfs folders).
   Pokemon Sword 1.3.2 is the tested version. Shield is recognized but not tested. Compressed .nsz / .xcz files are
   not supported: decompress them first.
2. A PC with:
   - Windows 10 or 11, 64-bit
   - A CPU with AVX2 (Intel Haswell / 2013 or newer, AMD Zen or newer)
   - A GPU with a Vulkan 1.3 driver (NVIDIA, AMD, Intel Arc / Iris Xe and newer)
   - 8 GB RAM or more (about 5 GB used while playing)
   - About 60 GB free disk space for the setup (about 20 GB stay used afterwards)

How to install
--------------
Installer (recommended): run PokemonSword-<version>-setup.exe. It installs for your user only (no administrator
rights) into %LOCALAPPDATA%\Programs\Pokemon Sword and adds Start menu and desktop shortcuts. The program is not
code-signed: if Windows says "Windows protected your PC", click "More info", then "Run anyway".

Zip (portable): unzip the PokemonSword folder anywhere you can write to (e.g. D:\Games\PokemonSword, not inside
Program Files) and open PokemonSword.exe.

How to set up the game (once)
-----------------------------
1. Open Pokemon Sword Recomp. The Game page says "Add your game".
2. Click "Choose game files" and select ALL your files at once (hold Ctrl and click each): the game .xci / .nsp, the
   update .nsp, the DLC .nsp files and your prod.keys. Click Open.
   - Tip: put them all in one folder first. A prod.keys sitting next to the game files is picked up by itself.
   - Already have an extracted game? Click "Use an extracted folder" instead and pick the folder that holds exefs and
     romfs (or any folder above it).
   - "Console keys" on the same page shows whether keys were found. Click it to choose a prod.keys file. Keys you
     give are kept in the keys\ folder, so you only do this once.
3. Wait. The launcher unpacks your files, builds the game data and recompiles the game code for your PC. This takes
   about 20 to 60 minutes depending on your CPU, only once. You can leave it running.
4. When the card says "Ready to play", click Play (or press A on a controller).

On the first start the game's shaders are prepared for your graphics card in the background (several minutes; the
game may stutter meanwhile). After that they are kept on disk (cache\).

Controls
--------
Controller: any controller Windows sees (Xbox, PlayStation, Switch Pro, handhelds such as the MSI Claw / ROG Ally /
Legion Go). The button layout follows the controller (Nintendo or Xbox) and can be changed.
In game, hold View / Minus for about a second to open the settings; Minus + Plus asks to close the game.
Keyboard: WASD move, Space/Enter = A, Q/Backspace = B, Tab = X (menu), R = Y, arrows = D-pad, F12 = settings,
F11 or Alt+Enter = full screen. All keys can be changed on the Controls page.

Settings worth knowing
----------------------
- Graphics > Detail: Balanced / High / Max (shadows, ambient occlusion, texture filtering).
- Graphics > Anti-aliasing: TAA + SMAA (sharpest and lightest), XeSS (Intel's, on any GPU; "Native AA (full size)" is
  the best image), NVIDIA DLAA on RTX cards when nvngx_dlss.dll is present.
- Display > Resolution, window / borderless / full screen, VSync, 30 or 60 fps.

Where things are kept
---------------------
Everything stays in the program's folder: settings (larecomp.ini), saves (save-sword\), keys (keys\), the game files
(extracted\), shader caches (cache\), mods (mods\) and the log (lasrecomp.log). Back up save-sword\ to keep your
progress. Installing a newer version over an old one keeps all of it (the game code is rebuilt by itself when needed).
Uninstalling keeps your saves, settings and keys; it asks before deleting the big game copy.

Troubleshooting
---------------
- "Add your prod.keys below": no keys were found. Click "Console keys" and choose your prod.keys.
- "Add the base game too": you picked only the update or DLC. Pick the game .xci / .nsp as well.
- "Unpack failed: see unpack.log": the keys don't match your files (dump them again from your Switch with current
  firmware), or a file is damaged. unpack.log is in the program's folder.
- "Not Pokemon Sword or Shield": pick your Pokemon Sword files.
- "Build tools missing: reinstall": an antivirus may have quarantined lasgen\lasgen.exe (sometimes flagged by mistake).
  Restore it or add the program's folder as an exception, then reinstall.
- The game closes or doesn't start: look at lasrecomp.log in the program's folder and report it on the project page.

Legal
-----
Fan project, not affiliated with Nintendo, The Pokemon Company, Game Freak or Creatures. MIT licensed (LICENSE.txt),
based on SwSh Recomp and Let's Go Recomp (https://github.com/raulzrrs) and LAS Recomp by Peiikai (LICENSE-LASRecomp.txt,
https://github.com/peiikai/LASRecomp).
Bundled: SDL3 (zlib), FFmpeg (LGPL 2.1, built with only the decoders the game needs; source: https://ffmpeg.org),
shaderc (Apache 2.0), Zig (MIT), nstool (MIT, https://github.com/jakcron/nstool), Intel XeSS (libxess.dll, Intel
Simplified Software License: LICENSE-XeSS.txt), the GCC / MinGW-w64 runtime libraries (GPL with the runtime library
exception).
