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
  **vinyl-sunset** look, the scootbar status bar (themed by the look),
  and Firefox.
- A welcome window on first login: what scoot is, the essential keys,
  Install/Try pointers and doc links, themed like the look. It reopens
  anytime from the **Welcome to scoot** launcher or the bar's
  **Welcome** button. (Implementation note: it is a styled local page,
  `file:///etc/scoot-welcome/index.html`, opened in Firefox — zero new
  binaries on an ISO where every megabyte counts toward the 2 GB
  release-asset cap, CSS theming straight from the look palette, and
  links that just work.)
- Calamares, with **scoot** in the Desktop list, selected by default.
- Autologin here is live-media-only (standard for installer ISOs). The
  installed system never autologins.

## What the installer writes

Picking scoot writes two small files to `/etc/nixos` on the target
(source of truth: `iso/target/` in this repo):

- `flake.nix`: inputs nixpkgs, scoot and home-manager pinned to the
  exact revs the ISO was built from, exposing
  `nixosConfigurations.scoot`.
- `configuration.nix`: imports scoot's NixOS modules
  (`nixosModules.scoot`, `nixosModules.scootbar`) and home-manager
  (`nixosModules.home-manager`), enables the desktop profile with the
  chosen look, the session entry, the ReGreet greeter
  (`programs.scoot.greeter`: greetd running ReGreet under cage), the
  scootbar, and the scoot Cachix substituter (so the install pulls
  binaries instead of compiling), plus the per-user desktop profile
  for the account created during install.

Install runs `nixos-install --flake /etc/nixos#scoot` with the flake
inputs overridden to the ISO's store paths, and the target closure
ships in the ISO (`isoImage.storeContents`), so install works with the
network cut — proven by `scripts/qemu-test.sh`, which installs inside
an emptied network namespace. After install, with network,
`nixos-rebuild switch --flake /etc/nixos#scoot` manages the system
normally.

The Calamares changes are a patch carried in this repo
(`nix/calamares-patch.py`, applied to
`calamares-nixos-extensions` by overlay at ISO build time) — never
upstream. Anchors are asserted exactly-once, so a nixpkgs re-pin that
changes upstream files fails the build loudly instead of silently
dropping scoot.

## How to pick another look

The ISO and the installer default to `vinyl-sunset`. The other looks
shipped by the pinned scoot are `music-desk` (light) and
`radial-burst` (dark); a fourth, `moonrise`, is in flight upstream and
will be offered here once the pinned scoot ships it.

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
