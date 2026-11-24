# Cask

**A free, open-source CrossOver alternative for macOS.** Run Windows games and apps on your Mac,
including Steam games whose Mac version no longer works (like 32-bit Portal). There's no license fee,
and it's MIT-licensed.

Cask is built on [Wine](https://www.winehq.org) (Gcenx's macOS builds) and runs on Apple Silicon through Rosetta 2.

## What it does

- **Bottles**: separate Windows setups with their own Windows version, graphics layer, Retina mode, msync, Metal HUD, env vars and pinned programs.
- **Automatic graphics**: Cask checks which DirectX each `.exe` uses and picks a layer:
  | Game uses | Layer | Notes |
  |---|---|---|
  | DirectX 1–9 (Portal, HL2, older games) | **WineD3D** → OpenGL | built into Wine |
  | DirectX 10/11 | **DXMT** → Metal (fallback: **DXVK-macOS** → MoltenVK) | downloaded automatically |
  | DirectX 12 | **VKD3D-Proton + DXVK on KosmicKrisp** (free, experimental) | macOS 26+ on Apple Silicon; disabled on older macOS |
  | DirectX 12 (alternative) | **D3DMetal** from Apple's Game Porting Toolkit | optional; you download GPTK, Cask imports it |
- **32-bit games** work through Wine's WoW64 mode, no 32-bit macOS needed.
- **Windows Steam** in its own bottle, installed for you.
- **`cask %command%`**: a Proton-style launch option for *Mac* Steam (see below).
- Opening an `.exe`/`.msi` from Finder (Open With → Cask) asks which bottle to run it in.

## Install

1. Download **Cask.dmg** from [Releases](../../releases/tag/latest) and drag Cask to Applications.
2. Cask is ad-hoc signed, not notarized, so macOS blocks it the first time you open it. Open it once, then go to **System Settings → Privacy & Security → Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Cask.app
   ```
3. In **Setup**, click **Set Up Everything** to install Wine, DXMT and DXVK. If Rosetta 2 is missing, Cask asks to install it.

### Free DirectX 12 (macOS 26+)
On macOS 26 or newer, Set Up Everything also installs Proton's DirectX 12 stack: [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton)
plus upstream [DXVK](https://github.com/doitsujin/dxvk), running on [KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html),
LunarG's open-source Vulkan driver built on Metal 4. Cask downloads LunarG's free Vulkan SDK once and keeps only the driver.
No Apple ID is needed. On older macOS the option is hidden and disabled. It's experimental: games that need DirectX 12
feature level 12_1 may not run.

### D3DMetal (optional, for DirectX 12)
Apple only lets you download the Game Porting Toolkit after signing in with a free Apple ID, and its license
doesn't allow anyone else to ship D3DMetal. In **Setup → D3DMetal**, click **Get GPTK**. Cask opens Apple's
page, you download the `.dmg`, and Cask finds it in your Downloads folder and imports it on its own.

## Playing Steam games

**Option A: Windows Steam (simplest).** In Setup, click **Install** next to Windows Steam, then **Open Steam**.
Sign in and install and play games like on a PC.

**Option B: from Mac Steam with `%command%` (like Proton).** Use this for games that show up in Mac Steam
but whose Mac build is broken, like Portal's old 32-bit one.

1. In Mac Steam, right-click the game → **Properties → Launch Options** and paste (Setup has a Copy button):
   ```
   "/Applications/Cask.app/Contents/Helpers/cask" %command%
   ```
2. Press **Play**. Cask reads the game's ID from Steam (`SteamAppId`) and asks **Windows Steam** (in the
   `Steam` bottle) to launch the **Windows** version.
   - First time only: Cask downloads Wine and installs Windows Steam. Sign in to it once.
   - If the Windows version isn't installed yet, Windows Steam shows its Install dialog. That's how it
     gets the Windows build, which Mac Steam never downloads. The game starts when the install finishes.
3. Cask hands the game over and exits, so Mac Steam doesn't think you're playing on two computers.

A Windows game needs a *Windows* Steam client for its Steam DRM (`steam_api.dll`), which is why Option B
runs through Windows Steam rather than Mac Steam.

If `%command%` is a `.exe` (for example a non-Steam shortcut), Cask runs it directly in `$CASK_BOTTLE`
(default: the Steam bottle).

## Command line

Setup → Command line → **Install** links `/usr/local/bin/cask`.

```sh
cask setup                          # Wine + DXMT + DXVK
cask status
cask create "My Games"
cask run -b "My Games" ~/Downloads/setup.exe
cask run -g dxmt -b "My Games" "~/Library/Application Support/Cask/bottles/My Games/drive_c/Games/game.exe"
cask steam install && cask steam
cask import-d3dmetal                # finds GPTK in ~/Downloads
cask tool winecfg -b "My Games"
cask kill
```

Data lives in `~/Library/Application Support/Cask` (`runtimes/`, `bottles/`, `components/`) and logs in `~/Library/Logs/Cask`.

## Building

GitHub Actions builds a universal `Cask.app`, `Cask.dmg` and `Cask.zip` on every push to `main` and publishes
them as the `latest` release. To build locally (macOS 14+, Xcode 16+):

```sh
scripts/bundle.sh
open dist/Cask.app
```

## Credits

Wine (LGPL) · [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) · [DXMT](https://github.com/3Shain/dxmt) ·
[DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) · DXVK · vkd3d-proton · KosmicKrisp (LunarG/Mesa) · MoltenVK · Apple Game Porting Toolkit (D3DMetal, user-supplied).
Cask downloads these at runtime. The one exception is vkd3d-proton, which Cask mirrors unmodified as .tar.gz (LGPL, source linked inside), because older macOS `tar` can't unpack zstd.

## License

MIT
