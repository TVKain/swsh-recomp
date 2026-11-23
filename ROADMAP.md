# Roadmap

What this fork plans next. The last release is **0.4.0** (installer, setup straight from `.xci` / `.nsp` + `prod.keys`,
XeSS, TAA v2, per-object motion vectors, 60 fps battles and menus). See [CHANGELOG.md](CHANGELOG.md) for what is done.

Legend: 🔜 next · 📋 planned · 🔍 needs research · ❓ needs testers

## Next

| | Item | Notes |
|---|---|---|
| 🔜 | **Handheld mode option** | The runtime always tells the game it is docked (`runtime/services/am.c`, GetOperationMode = 1). Handheld makes Sword render at 1280×720 with its own lighter settings: a real speed option for handhelds and integrated GPUs. Setting `operation_mode = docked \| handheld` (restart), launcher Graphics page. Check what the game changes in handheld mode (resolution, LOD, effects) and that it does not affect controls. |
| 🔜 | **"Download DLSS" button** | Brings back DLAA on RTX cards without shipping NVIDIA's file: the launcher downloads `nvngx_dlss.dll` from NVIDIA's own GitHub (`NVIDIA/DLSS`, a pinned version) on request, checks size + SHA-256, writes it next to the exe, and keeps a newer copy if one is already there. The DLAA code path already exists. ❓ Needs an RTX tester. |
| 📋 | **Draw distance** | Keep detailed people / Pokémon models farther away. Find Sword's model-LOD manager (global pointer + vtable check), raise its distance thresholds, check every guest pointer before following it, never grow the game's memory pools. |
| 📋 | **RecompLauncher listing** | A `recomplauncher.json` manifest in the repo (inputs: game, update, DLC, `prod.keys`; `prepare` and `start` commands; config file, saves and log folders). Needs a headless command line: `PokemonSword.exe --prepare --game <xci/nsp> --update <nsp> --dlc=<nsp> --keys <prod.keys> --target <dir>`, a "ready" marker file, and `--play --target <dir>`. |

## Planned

| | Item | Notes |
|---|---|---|
| 📋 | **Saves page** in the launcher | Export the save as a `.zip`, import one, open its folder, restore one of the last automatic backups (keep a few rotating copies before each start). |
| 📋 | **Feedback report** | One button that writes a ready-to-paste report for a GitHub issue: version, GPU + driver, CPU, settings, the end of `lasrecomp.log`. No paths with user names, no keys. |
| 📋 | **Resumable setup** | A stopped or failed setup continues where it stopped (unpack, romfs build, game-code compile per object) instead of starting over. |
| 📋 | **CPUs without AVX2** | Detect at setup and compile the game code without AVX2 instead of failing at start. |
| 📋 | **Self-update check** | Launcher notices a newer GitHub release and offers to download the installer; saves and settings stay. |
| 🔍 | **Outdoor performance** | Route 1 / Wild Area / cities not measured on weaker GPUs yet. Needs saves past Postwick for test scenarios. |
| 🔍 | **Area-load hitch** | 200–250 ms per area load, almost half in translated sin/cos (`docs/engineering/known-issues.md`, LOADS). |
| ❓ | **60 fps in other battles** | Trainer, double and Max Raid battles are not checked yet (the battle pacing hook keys on the wild-battle main object). |
| ❓ | **Other GPUs** | Only tested on Intel Arc 140V. NVIDIA / AMD reports welcome. |
| ❓ | **Pokémon Shield** | Recognised, not tested. |

## Ideas from PokiNative

[PokiNative](https://github.com/privacymatters42069-del/PokiNative) (Scarlet / Violet, a KarPur fork, MIT; no longer
developed) is further along on PC extras. Reviewed 2026-11-23.

**Worth copying** (all listed above):
- Handheld mode as a performance option (their `OPERATION_MODE = docked | handheld`).
- DLSS downloaded from NVIDIA on request with a pinned version and checksum (their launcher `DownloadDlss`).
- RecompLauncher manifest + headless `--prepare` / `--play` command line.
- Model detail distance (their `runtime/sv_detail.c`): LOD thresholds written into the game's model manager, every
  guest pointer checked with a memory query first, memory pools untouched.
- Launcher Saves tab, Feedback report, resumable build, non-AVX2 build.
- Their docs style: a "Compatibility switches" section in Troubleshooting, and a clear table of which dumps are tested.

**Not copying:**
- FSR 2: TAA v2 and XeSS already cover anti-aliasing / upscaling here.
- DLSS Frame Generation: needs NVIDIA Streamline files the player must supply, RTX 40+ only.
- More wild Pokémon, no version exclusives, no trade evolutions: built on Scarlet / Violet's data and addresses. Could be
  redone for Sword later, but they change the game, not the port.
- Downloading Python / a compiler at setup: our installer already ships the build tools (lasgen, zig).
