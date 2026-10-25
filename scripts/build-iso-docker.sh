#!/usr/bin/env bash
# Build the scoot-iso ISO with one Docker command (no nix on the host).
#
# Copy-paste:
#   scripts/build-iso-docker.sh
#
# The .iso lands in ./scoot-iso-out/ owned by you. x86_64 and aarch64
# build natively. Cross-arch (e.g. the x86_64 ISO on an Apple Silicon
# Mac: ISO_PLATFORM=linux/amd64) runs the image under emulation
# (Docker Desktop's Rosetta or qemu-user), which is much slower; the
# script then turns off Nix's build seccomp filter, which emulation
# cannot load (see FOREIGN below).
#
# What it does: runs the pinned official nixos/nix image (per-arch
# digest below), which runs `nix build <flake>#iso` with the scoot
# Cachix plus cache.nixos.org substituters, then copies the .iso out
# with your UID/GID (files a container writes would otherwise belong
# to root).
#
# Env knobs:
#   ISO_FLAKE   flake to build (default github:scoot-sh/scoot-iso)
#   ISO_ATTR    attribute (default iso; the container's native arch picks
#               the system, or pass .iso.x86_64-linux explicitly)
#   ISO_OUTDIR  where the .iso lands (default ./scoot-iso-out)
#   ISO_PLATFORM  docker --platform (default: native)
#   ISO_DOCKER_IMAGE  full image ref override (default: pinned digest
#               for the native arch)
#   --check     instead of the ISO, run `nix flake check` in the image
#               (fast plumbing validation for CI and first-time setup)
#
# The live session defaults to the moonrise look and the installer
# offers all four looks on its Desktop page, so looks need no build
# knob; likewise the flake location (home vs /etc/nixos) is an
# installer choice. Disk/time: about 20 GB free and ~30 min on a warm
# cache (the script prints elapsed time and the output listing).
set -euo pipefail

# Pinned official nixos/nix image digests (2026-10-06; re-pin from
# the manifest list and update both arch digests below).
DIGEST_AMD64="sha256:617d914dba5384bf75adf17081583b69371031ec7defce36c34c5fa14fc819b0"
DIGEST_ARM64="sha256:a326ac1ed46069ead5cdcba3a3a1e7255ebf72300c8319bf2c12cacfe9ab2787"

FLAKE="${ISO_FLAKE:-github:scoot-sh/scoot-iso}"
ATTR="${ISO_ATTR:-iso}"
OUTDIR="${ISO_OUTDIR:-scoot-iso-out}"
PLATFORM="${ISO_PLATFORM:-}"
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) NATIVE_DIGEST="$DIGEST_AMD64" ;;
  arm64|aarch64) NATIVE_DIGEST="$DIGEST_ARM64" ;;
  *) echo "unsupported arch $ARCH" >&2; exit 2 ;;
esac
# The image must match the platform Docker will actually run: an
# arm64 digest with --platform linux/amd64 fails with a platform
# mismatch instead of emulating (the digest pins one arch's manifest,
# verified with `docker manifest inspect --verbose`). So the digest
# follows the EFFECTIVE platform — ISO_PLATFORM when set, else native.
case "$PLATFORM" in
  linux/amd64) DIGEST="$DIGEST_AMD64" ;;
  linux/arm64) DIGEST="$DIGEST_ARM64" ;;
  "") DIGEST="$NATIVE_DIGEST" ;;
  *) echo "unsupported ISO_PLATFORM $PLATFORM (want linux/amd64 or linux/arm64)" >&2; exit 2 ;;
esac
IMAGE="${ISO_DOCKER_IMAGE:-nixos/nix@$DIGEST}"

PLATFORM_ARG=""
if [ -n "$PLATFORM" ]; then PLATFORM_ARG="--platform $PLATFORM"; fi

# A foreign platform runs emulated, and emulation cannot load the
# seccomp BPF program Nix installs around every build: under Docker
# Desktop's Rosetta every build fails at sandbox setup with
# "unable to load seccomp BPF program: Invalid argument". So for a
# foreign platform only, pass `filter-syscalls false`. Natively the
# filter stays on: it is what stops builds from creating setuid/setgid
# files or extended attributes, and it costs nothing there.
case "$ARCH" in
  x86_64) NATIVE_PLATFORM=linux/amd64 ;;
  *) NATIVE_PLATFORM=linux/arm64 ;;
esac
FOREIGN=0
if [ -n "$PLATFORM" ] && [ "$PLATFORM" != "$NATIVE_PLATFORM" ]; then FOREIGN=1; fi

CACHIX_SUB="https://scoot-sh.cachix.org"
CACHIX_KEY="scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
NIXFLAGS="--extra-experimental-features 'nix-command flakes' --extra-substituters '$CACHIX_SUB' --extra-trusted-public-keys '$CACHIX_KEY'"
if [ "$FOREIGN" = 1 ]; then
  NIXFLAGS="$NIXFLAGS --option filter-syscalls false"
  echo "note: $PLATFORM is emulated on this $ARCH host (slow); building with filter-syscalls off" >&2
fi

if [ "$CHECK" = 1 ]; then
  # shellcheck disable=SC2086
  docker run --rm $PLATFORM_ARG \
    "$IMAGE" \
    sh -c "nix $NIXFLAGS flake check '$FLAKE' --print-build-logs"
  exit 0
fi

mkdir -p "$OUTDIR"
case "$OUTDIR" in
  /*) MOUNT="$OUTDIR" ;;
  *) MOUNT="$PWD/$OUTDIR" ;;
esac
START=$(date +%s)
# shellcheck disable=SC2086
docker run --rm $PLATFORM_ARG \
  -e CALLER_UID="$(id -u)" -e CALLER_GID="$(id -g)" \
  -v "$MOUNT:/out" \
  "$IMAGE" \
  sh -c "nix $NIXFLAGS build '$FLAKE#$ATTR' --print-build-logs -o /tmp/iso-result && iso=\$(echo /tmp/iso-result/iso/*.iso) && cp \"\$iso\" /out/ && chown \"\$CALLER_UID:\$CALLER_GID\" /out/\$(basename \"\$iso\") && sha256sum /out/\$(basename \"\$iso\")"
END=$(date +%s)
echo "done in $(( (END - START) / 60 ))m$(( (END - START) % 60 ))s; output in $OUTDIR:"
ls -la "$OUTDIR"
