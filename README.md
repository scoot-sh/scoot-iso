# scoot-iso

A NixOS live + installer ISO with the scoot desktop: boot the USB stick
and you are in a full scoot session; run the installer and the target
gets the scoot desktop profile with the ReGreet login screen.

> Screenshots: the live session, the welcome window and Calamares'
> Desktop page will be attached here after the first green CI QEMU run
> (they are produced reproducibly: the live and installed shots come
> from `scripts/qemu-test.sh` via QMP screendump plus `scoot msg
> screenshot --out`, never hand captures). Until then, no image here is
> better than a stale one.

## One command

```sh
nix build github:scoot-sh/scoot-iso#iso
```

That builds for your Nix system (`x86_64-linux` or `aarch64-linux`;
pick `.iso.x86_64-linux` / `.iso.aarch64-linux` explicitly). The same
system is also available as a flake output for `nixos-rebuild`:

```sh
nixos-rebuild build-image --image-variant iso-installer \
  --flake github:scoot-sh/scoot-iso#scoot-live-x86_64-linux
```

Without nix, the same build runs in Docker (pinned official
`nixos/nix` image, scoot Cachix plus cache.nixos.org so most of it
downloads); the `.iso` lands in `./scoot-iso-out/` owned by you:

```sh
scripts/build-iso-docker.sh
```

`ISO_PLATFORM=linux/amd64` builds x86_64 on an ARM Mac (emulated,
slow); natively each arch builds its own ISO. The script prints
elapsed time and the output listing; `scripts/build-iso-docker.sh
--check` runs `nix flake check` in the image instead (fast plumbing
validation). About 20 GB free and some 30 minutes on a warm cache.

When release hosting exists, downloading the ISO is the third way;
until then there are two. GitHub release assets cap at 2 GB (see
below), so first releases publish out of band.

Apple Silicon Macs need the Asahi installer, not this ISO: bare-metal
Apple Silicon boots only through Apple's bootloader chain, which a
generic ISO cannot provide.

## Flashing to USB

```sh
# Replace /dev/sdX with the stick (check with lsblk first; this erases it).
sudo dd if=$(echo result-iso/iso/*.iso) of=/dev/sdX bs=4M status=progress oflag=sync
```

Or with a GUI writer (GNOME Disks, balenaEtcher): pick the `.iso` file.
Boot the stick in UEFI mode.

## What you get on the live session

- A scoot session straight after boot (no login prompt): full desktop
  profile (`programs.scoot.desktop.enable = true`) with the
  **moonrise** look, its night-sky wallpaper, the scootbar status bar
  (themed by the look), and Firefox.
- A welcome window on first login: what scoot is, the essential keys,
  Install/Try pointers and doc links, designed in moonrise. It reopens
  anytime from the **Welcome to scoot** launcher or the bar's
  **Welcome** button. (Implementation note: it is a styled local page,
  `file:///etc/scoot-welcome/index.html`, opened in Firefox — zero new
  binaries on an ISO where every megabyte counts toward the 2 GB
  release-asset cap, CSS theming straight from the look palette, and
  links that just work.)
- Calamares, with four **scoot** entries in the Desktop list (one per
  look: moonrise, music-desk, radial-burst, vinyl-sunset),
  **scoot (moonrise)** selected by default.
- Autologin here is live-media-only (standard for installer ISOs). The
  installed system never autologins. The live session also never locks
  or blanks the screen (the profile's idle policy is switched back off
  for live media only: an install outlasts every idle timeout, and a
  locked live session would stall Calamares mid-write); the installed
  system keeps the profile default — dim at 2 minutes, lock at 4,
  screens off at 5.

## What the installer writes

Picking scoot writes a flake to the target (source of truth: `iso/target/`
in this repo), then builds the first system from it with
`nixos-install --flake <config-dir>#scoot` (no input overrides,
`--no-write-lock-file`, `--no-channel-copy`, `substitute = false`,
network cut):

- `flake.nix`: inputs nixpkgs, scoot and home-manager pinned to the
  exact revs the ISO was built from, exposing
  `nixosConfigurations.scoot`.
- `flake.lock`: the same pins resolved to real upstream (`github:`)
  inputs — never the installer's `path:` overrides — so the installed
  system is a normal maintainable flake afterwards.
- `configuration.nix`: imports scoot's NixOS modules
  (`nixosModules.scoot`, `nixosModules.scootbar`) and home-manager
  (`nixosModules.home-manager`), enables the desktop profile with the
  chosen look, the session entry, the ReGreet greeter
  (`programs.scoot.greeter`: greetd running ReGreet under cage,
  wearing the chosen look too — its wallpaper behind a dark GTK theme
  with an accent Login button, except the light music-desk look which
  gets the light theme), the
  scootbar, `programs.nh` pointed at the flake itself, and the scoot
  Cachix substituter (so the install pulls binaries instead of
  compiling), plus the per-user desktop profile for the account created
  during install.
- `hardware-configuration.nix`: generated on the target as usual.

Where the flake lives is a choice on the installer's Config-location
page (a second packagechooser page carried by the same patch):

- **In my home folder (recommended, default):**
  `~/nixos-config`, owned by you, a git repo with a first commit;
  `/etc/nixos` is a symlink to it, so `sudo nixos-rebuild switch` and
  every `/etc/nixos`-assuming guide still work. Edit as yourself and
  rebuild with `nh os switch` (or
  `nixos-rebuild switch --flake ~/nixos-config#scoot`).
- **System-wide in /etc/nixos:** the classic root-owned layout (also a
  git repo with a first commit, no symlink,
  `programs.nh.flake = "/etc/nixos"`). Edit with sudo and rebuild with
  `sudo nixos-rebuild switch` (or `nh os switch`).

```nix
# ~/nixos-config/configuration.nix, after installing:
programs.scoot.desktop.look = "music-desk";
# ... and the home-manager user half in the same file, then:
# nh os switch
```

Install runs fully offline, proven by `scripts/qemu-test.sh`, which
installs inside an emptied network namespace, then reboots and
rebuilds the installed system offline both ways (`nixos-rebuild build`
and `nh os switch`). Three pieces make it work:

- Every flake input source the target needs rides the ISO (resolved
  from the target's own lock at ISO build time into
  `isoImage.storeContents`), so no `--override-input` is needed and
  the installed `flake.lock` stays pristine `github:` pins.
- The reference target (`nix/target-machine.nix`) names the exact
  system the test installs (same inputs, user, host, options, look,
  static QEMU hardware), so its toplevel — also in
  `isoImage.storeContents` — is the installed closure bit for bit.
  `tests/render_check.py` gates that they evaluate to the same
  toplevel (drvPath match), so they cannot drift.
- The installer pre-copies that closure from the live store into the
  empty target store (`nix copy --to`, since building into the target
  store does not consult the live store) and skips the legacy channel
  (`--no-channel-copy`: a flake system never reads channels, and the
  copy cannot work offline).

After install, with network,
`nixos-rebuild switch --flake /etc/nixos#scoot` manages the system
normally (the symlink resolves it to your home copy).

The Calamares changes are a patch carried in this repo
(`nix/calamares-patch.py`, applied to
`calamares-nixos-extensions` by overlay at ISO build time) — never
upstream. Anchors are asserted exactly-once, so a nixpkgs re-pin that
changes upstream files fails the build loudly instead of silently
dropping scoot.

## How to pick another look

The ISO and the installer default to `moonrise`. The other looks
shipped by the pinned scoot are `music-desk` (light),
`radial-burst` (dark) and `vinyl-sunset` (warm dark, no wallpaper image
ships for it: its illustration's license forbids passing it on
standalone, so the session shows its flat background color). In the
Calamares Desktop list each look is its own **scoot** entry, so the
choice happens at install time; moonrise is pre-selected.

On an installed system, set the look in both halves and rebuild:

```nix
# /etc/nixos/configuration.nix (system half):
programs.scoot.desktop.look = "music-desk";
# ... and the home-manager user half in the same file:
home-manager.users."<you>".programs.scoot.desktop.look = "music-desk";
# then:
nixos-rebuild switch --flake /etc/nixos#scoot
```

To try a look on the live session before installing, the same two
options (system `programs.scoot.desktop.look` in `nix/live.nix` plus
the welcome/config colors) are the only place the default lives.

## Wallpaper credit

The moonrise wallpaper (`docs/assets/wallpapers/moonrise.png` in the
pinned scoot, shown by the live session, the installed default and the
welcome page's hero banner) is &ldquo;Silhouetted trees under moon and
stars&rdquo; by saatvik 5554
([@saatvik_reddy_suravaram](https://unsplash.com/@saatvik_reddy_suravaram)),
published on Unsplash
([illustration page](https://unsplash.com/illustrations/silhouetted-trees-under-moon-and-stars-jwBJOj6gakI)).
It is free to use under the [Unsplash License](https://unsplash.com/license),
which allows downloading, copying, modifying and distributing it,
including commercially and without attribution. It is not part of scoot's
MIT-licensed code and stays under the Unsplash License wherever scoot-iso
is redistributed; see scoot's `NOTICE`.

## ISO size and hosting

GitHub release assets cap at 2 GB. CI measures the ISO on every build
and prints the size to the job summary. If a release ISO is under the
cap it is attached to the GitHub release; if it is over, the release
job attaches `SHA256SUMS` only and the ISO is published out of band
(a static file host or torrent — TBD at first release), with the
checksum file as the trust anchor.

## Troubleshooting by symptom

- **The live session boots to a login prompt instead of scoot.**
  The ISO's greetd initial session failed. Switch to a VT
  (Ctrl+Alt+F2), log in as `nixos`, and read
  `journalctl -u greetd -b` plus `journalctl -u scoot-live-seed -b`.
- **The Welcome window never opened.**
  The autostart entry runs once per live boot
  (`~/.cache/scoot-iso/welcomed` marks it). Delete that flag and
  re-login, or open `file:///etc/scoot-welcome/index.html` in Firefox
  directly. If the file is missing, `scoot-live-seed` failed —
  `journalctl -u scoot-live-seed -b`.
- **The bar is missing but windows work.**
  `systemctl --user status scootbar` as `nixos` (the profile starts it
  through `graphical-session.target`). If the unit is absent, the
  `programs.scootbar` module did not enable — check the ISO revision
  matches this repo's flake inputs.
- **Calamares shows no scoot choice.**
  The overlay did not apply (the ISO was built without the patch, or
  nixpkgs was re-pinned past the asserted anchors and the build
  should have failed — report it). Verify with:
  `nix flake check github:scoot-sh/scoot-iso` (runs
  `patch-consistency`).
- **Install fails with the network cut.**
  A closure path is missing from the ISO store. The QEMU test installs
  network-less on every run; if it regressed, compare
  `nix path-info -r` of the reference target
  (`nixosConfigurations.scoot-target-x86_64-linux`) against the ISO's
  `isoImage.storeContents` and check which path the installer tried to
  fetch in `/tmp/install.log` (saved by the QEMU script).
- **Installed system boots to a black screen.**
  ReGreet (cage) is up but the scoot session failed: switch to a VT,
  log in, `journalctl --user-unit scoot-session.target -b` and
  `scoot msg version` after starting a headless session. If the
  greeter itself is missing, `systemctl status greetd`.
- **`sudo nixos-rebuild switch` fails with "not owned by current user".**
  With the home-folder layout the flake belongs to you, and root
  cannot evaluate it (libgit2 ownership). Rebuild as yourself with
  `nh os switch` (recommended: `programs.nh.flake` already points at
  your copy) or `nixos-rebuild switch --use-remote-sudo --flake
  ~/nixos-config#scoot` — never plain `sudo nixos-rebuild`.
- **The installed system autologins.**
  That is a bug — the installer refuses Calamares' autologin snippets
  for the scoot choice by design. Report it with the contents of
  `/etc/nixos/configuration.nix`.

## Developing

```sh
nix flake check          # patch-consistency + module eval (cheap, runs everywhere)
nix flake lock --update-input scoot   # re-pin scoot (then re-verify the look list + anchors)
```

Re-pinning nixpkgs requires re-verifying the Calamares anchors (the
patch fails loudly if they moved) and the parity between
`iso/target/configuration.nix` and `nix/target-machine.nix`
(`patch-consistency` enforces the load-bearing lines).
