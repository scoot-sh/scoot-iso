#!/usr/bin/env bash
# QEMU end-to-end test for scoot-iso (runs in CI, x86_64 with KVM).
#
# 1. Boots the ISO (live session autobots into scoot; screendump it).
# 2. Proves the live ISO ships our installer patch with byte-exact
#    templates (repr-embedding check against the shipped main.py), then
#    proves the installer's network-mode logic piece by piece:
#    2a. a non-canonical hardware tweak (an extra initrd module), with
#        the network cut, must REFUSE before partitioning, naming the
#        missing store paths ("connect to the network, or ..."), with
#        the disk untouched;
#    2b. the canonical config, with the network cut, installs offline
#        from the shipped store (pre-copy + substitute=false), exactly
#        as the patched Calamares would;
#    2c. the same tweak, with the network up, installs with the normal
#        substituters (set QEMU_TEST_ONLINE_TWEAK=0 to skip: it doubles
#        the run, and CI may prove only the offline half).
# 3. Reboots the installed disk into ReGreet (screendump), logs in, and
#    checks scoot + bar + wallpaper via `scoot msg` and screenshots,
#    all through the QEMU guest agent.
#
# The offline install exercises the CANONICAL config only (user scoot,
# host scoot, UTC, en_US.UTF-8, 25.11, moonrise, home-folder layout,
# static QEMU hardware): it must match nix/target-machine.nix exactly,
# whose toplevel rides the ISO in isoImage.storeContents. With
# `substitute = false` any drift fails here loudly instead of phoning
# home; tests/render_check.py gates the drvPath match in CI's check
# job. Real installs on real hardware still run nixos-generate-config
# (their hardware varies); only this test uses the static file.
#
# Guest control uses QMP (screendump, send-key) and qemu-ga guest-exec
# as root (enabled on live media by nixpkgs' graphical base and on the
# target by services.qemuGuest.enable), so no credentials are baked
# into the ISO. stdlib python3 + qemu-img + OVMF only.
#
# Arch: defaults target x86_64 (CI). For aarch64 (Asahi-native or
# Apple Silicon+HVF) export QEMU_BIN=qemu-system-aarch64,
# QEMU_MACHINE="virt,accel=hvf" (or "...,accel=kvm:tcg" under KVM),
# QEMU_CPU=host, QEMU_MEM=3G and point OVMF_CODE/VARS at the AAVMF
# firmware.
#
# Usage:
#   scripts/qemu-test.sh --iso <iso> --target-flake <path>
#     --target-config <path> --target-hardware <path> --workdir <dir>
#     [--user scoot] [--password testpass123] [--system x86_64-linux]
set -euo pipefail

ISO=""
TARGET_FLAKE=""
TARGET_CONFIG=""
TARGET_HARDWARE=""
WORKDIR=""
TEST_USER="scoot"
TEST_PASS="testpass123"
SYSTEM="x86_64-linux"
# Phase 2c (the same hardware tweak installed with the network up)
# doubles the run (a second full install + boot). CI may skip it and
# prove only the offline half; a local run proves both.
ONLINE_TWEAK="${QEMU_TEST_ONLINE_TWEAK:-1}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MACHINE="${QEMU_MACHINE:-q35,accel=kvm:tcg}"
QEMU_CPU="${QEMU_CPU:-max}"
QEMU_MEM="${QEMU_MEM:-4G}"
QEMU_SMP="${QEMU_SMP:-4}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --target-flake) TARGET_FLAKE="$2"; shift 2 ;;
    --target-config) TARGET_CONFIG="$2"; shift 2 ;;
    --target-hardware) TARGET_HARDWARE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --user) TEST_USER="$2"; shift 2 ;;
    --password) TEST_PASS="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$ISO" ] && [ -n "$TARGET_FLAKE" ] && [ -n "$TARGET_CONFIG" ] && [ -n "$TARGET_HARDWARE" ] && [ -n "$WORKDIR" ] || {
  echo "missing required args" >&2; exit 2
}
[ -f "$OVMF_CODE" ] || { echo "OVMF code missing: $OVMF_CODE" >&2; exit 2; }
[ -f "$OVMF_VARS_SRC" ] || { echo "OVMF vars template missing: $OVMF_VARS_SRC" >&2; exit 2; }

mkdir -p "$WORKDIR"
DISK="$WORKDIR/disk.qcow2"
VARS="$WORKDIR/OVMF_VARS.fd"
QMP="$WORKDIR/qmp.sock"
GASOCK="$WORKDIR/ga.sock"
LOG="$WORKDIR/qemu-test.log"
[ -f "$VARS" ] || { cp "$OVMF_VARS_SRC" "$VARS" && chmod u+w "$VARS"; }
qemu-img create -f qcow2 "$DISK" 24G >/dev/null
exec > >(tee "$LOG") 2>&1

# --- QMP helpers (stdlib python) -------------------------------------------
qmp() {
  python3 - "$QMP" "$@" <<'EOF'
import json, socket, sys
path, args = sys.argv[1], sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
name = args[0]
params = json.loads(args[1]) if len(args) > 1 else {}
print(json.dumps(cmd({"execute": name, "arguments": params})))
EOF
}

# Guest control goes DIRECTLY over the chardev socket ($GASOCK), not
# through QMP guest-* commands: on these runners QMP answers
# query-status/screendump/send-key fine, but QMP guest-ping never gets
# a reply even with the agent up, the virtio port bound and KVM on
# (proven over three runs), while the identical ping sent straight over
# this socket answers {"return": {}} instantly. So the script speaks the
# qemu-ga protocol itself (stdlib python): guest-sync-delimited framing
# per connection, guest-exec, then guest-exec-status polling. QMP stays
# for monitor commands only (status, screendump, send-key, quit).
#
# One hard rule from the transport experiment: input-data arrives
# corrupt (a 13-byte stdin failed outright; 600 sent bytes arrived as
# 450), while argv arrives intact. So scripts travel in argv (-c),
# never in input-data; anything bulk-sized is read from files already
# in the guest (the shipped main.py embeds the installer templates).
qga() {
  python3 - "$GASOCK" "$@" <<'EOF'
import base64, json, socket, sys, time
path, args = sys.argv[1], sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(path)
f = s.makefile("rwb")
def transact(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("qga socket closed mid-command")
        line = line.lstrip(b"\xff")  # guest-sync-delimited marker
        try:
            msg = json.loads(line)
        except ValueError:
            continue  # stray async event; keep reading
        if "return" in msg or "error" in msg:
            return msg
syncid = 9871
r = transact({"execute": "guest-sync-delimited", "arguments": {"id": syncid}})
if r.get("return") != syncid:
    raise SystemExit(f"qga sync failed: {r}")
mode = args[0]
if mode == "ping":
    r = transact({"execute": "guest-ping"})
    print(json.dumps(r))
elif mode == "exec":
    script = args[1]
    r = transact({"execute": "guest-exec", "arguments": {"path": "/bin/sh", "arg": ["-c", script], "capture-output": True}})
    if "error" in r:
        raise SystemExit(f"guest-exec refused: {r}")
    pid = r["return"]["pid"]
    # 90 minutes: the offline install block (closure pre-copy plus
    # nixos-install) is the longest single guest command, and slow
    # disks need most of it; the old 30-minute ceiling killed green
    # HVF runs mid-install.
    for _ in range(2700):
        r = transact({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if "error" in r:
            raise SystemExit(f"guest-exec-status refused: {r}")
        ret = r["return"]
        if ret.get("exited"):
            print("rc:", ret.get("exitcode"))
            o = ret.get("out-data")
            if o:
                sys.stdout.write(base64.b64decode(o).decode(errors="replace"))
            e = ret.get("err-data")
            if e:
                sys.stderr.write(base64.b64decode(e).decode(errors="replace"))
            sys.exit(ret.get("exitcode", 1))
        time.sleep(2)
    raise SystemExit("guest-exec timed out")
EOF
}

# guest_exec <shell-command>: run via qemu-ga as root, poll, print output.
# The command travels in argv (see above); keep each invocation small
# (a few KB at most) and read bulk data from guest files instead. The
# agent's PATH is bare, so every command starts with the system profile
# on PATH (NixOS keeps all system tools in /run/current-system/sw/bin).
guest_exec() {
  qga exec "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; $1"
}

wait_ga() {
  local n=0
  for _ in $(seq 1 150); do
    n=$((n + 1))
    if qga ping 2>/dev/null | grep -q '"return": {}'; then return 0; fi
    if [ $((n % 12)) -eq 0 ]; then echo "still waiting for guest agent (${n}x5s)..."; qmp query-status '{}' 2>/dev/null || echo "QMP unreachable"; qmp screendump "{\"filename\": \"$WORKDIR/boot-progress-$n.ppm\"}" >/dev/null 2>&1 || echo "progress screendump failed"; fi
    sleep 5
  done
  echo "guest agent never came up" >&2
  echo "--- QMP status at failure ---"
  qmp query-status '{}' 2>/dev/null || echo "QMP unreachable"
  echo "--- failure screendump ---"
  qmp screendump "{\"filename\": \"$WORKDIR/boot-failure.ppm\"}" >/dev/null 2>&1 || echo "screendump failed"
  echo "--- serial tail ---"
  tail -30 "$WORKDIR"/serial-*.log 2>/dev/null || echo "no serial log"
  echo "--- qemu process ---"
  pgrep -af "qemu-system" || echo "no qemu process"
  return 1
}

start_vm() {
  # start_vm <boot> : boot = d (ISO) or c (disk)
  local boot="$1"
  rm -f "$QMP" "$GASOCK"
  local extra=()
  if [ "$boot" = d ]; then extra+=(-cdrom "$ISO" -boot order=d); else extra+=(-boot order=c); fi
  # shellcheck disable=SC2068
  $QEMU_BIN \
    -machine "$QEMU_MACHINE" -cpu "$QEMU_CPU" -m "$QEMU_MEM" -smp "$QEMU_SMP" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",if=virtio,format=qcow2 \
    ${extra[@]} \
    -device virtio-gpu-pci -display none \
    -device qemu-xhci -device usb-tablet -device usb-kbd \
    -serial file:"$WORKDIR/serial-$boot.log" \
    -netdev user,id=net0,hostfwd=tcp::10022-:22 \
    -device virtio-net-pci,netdev=net0 \
    -chardev socket,path="$GASOCK",server=on,wait=off,id=qga0 \
    -device virtio-serial-pci \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -qmp unix:path="$QMP",server=on,wait=off \
    -daemonize -pidfile "$WORKDIR/qemu.pid"
  sleep 3
  if ! kill -0 "$(cat "$WORKDIR/qemu.pid")" 2>/dev/null; then
    echo "qemu died right after start (KVM unusable? OVMF/ISO path wrong?)" >&2
    return 1
  fi
  echo "--- QMP status after start ---"
  qmp query-status '{}' || echo "QMP unreachable right after start"
  echo "--- KVM or TCG? ---"
  python3 - "$QMP" <<'EOF' || echo "info-kvm query failed"
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
print(json.dumps(cmd({"execute": "human-monitor-command", "arguments": {"command-line": "info kvm"}})))
EOF
}

stop_vm() {
  qmp quit '{}' >/dev/null 2>&1 || true
  sleep 3
  pkill -F "$WORKDIR/qemu.pid" 2>/dev/null || true
}

echo "=== phase 1: boot live ISO ==="
start_vm d
wait_ga
guest_exec 'echo "PATH=$PATH"; command -v python3 base64 wc pgrep sgdisk git nixos-install; ls /run/current-system/sw/bin/python3*' || true
sleep 20 # let the scoot session settle
qmp screendump "{\"filename\": \"$WORKDIR/live-session.ppm\"}" >/dev/null
echo "live screenshot: $WORKDIR/live-session.ppm"

echo "=== phase 1b: the welcome window ==="
# The live session autostarts Firefox with the welcome page once per
# boot. Wait for the window to appear, then screenshot it on its own:
# `scoot msg windows` lists it, which also proves the compositor's IPC
# answers on the live session.
for _ in $(seq 1 24); do
  if guest_exec 'pgrep -af "[f]irefox --new-window" >/dev/null && echo FIREFOX-UP' 2>/dev/null | grep -q FIREFOX-UP; then break; fi
  sleep 5
done
echo "--- welcome spawn env (what scoot autostart children inherit) ---"
guest_exec 'cat /tmp/scoot-welcome-env.txt' || true
echo "--- welcome browser log (firefox stderr; profile errors land here) ---"
guest_exec 'tail -30 /tmp/scoot-firefox.log 2>/dev/null || echo NO-FIREFOX-LOG' || true
msg_ok=0
for _ in $(seq 1 24); do
  if guest_exec 'export XDG_RUNTIME_DIR=/run/user/$(id -u nixos); export SCOOT_SOCKET=$XDG_RUNTIME_DIR/scoot.sock; [ -S "$SCOOT_SOCKET" ] && su -s /bin/sh nixos -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg windows"'; then msg_ok=1; break; fi
  sleep 5
done
[ "$msg_ok" = 1 ] || echo "MSG-WARN: live-session scoot msg never answered; headless check in phase 3c remains the hard IPC proof"
echo "--- browser probes (diagnostic; never fatal) ---"
guest_exec '
echo "--- browser processes ---"; pgrep -af "[f]irefox --new-window" || true
echo "--- browser env ---"
for pid in $(pgrep -f "[f]irefox --new-window"); do echo "== $pid =="; tr "\0" "\n" < /proc/$pid/environ | grep -E "^(HOME|USER|LOGNAME|XDG_RUNTIME_DIR|WAYLAND_DISPLAY|SCOOT_SOCKET|MOZ_|DBUS_SESSION)" || true; done
echo "--- nixos home ---"; ls -la /home/nixos/ | head -20
echo "--- mozilla dir (seeded profile + populated default) ---"; ls -la /home/nixos/.mozilla/firefox/ 2>&1 || true
echo "--- browser stderr from the session journal ---"; sudo -u nixos journalctl --user -b --no-pager 2>/dev/null | grep -iE "firefox|mozilla|profile|NS_ERROR" | head -20 || true
echo "--- crashes? ---"; coredumpctl list --no-pager 2>/dev/null | head -5 || true
id nixos
exit 0
' || true
sleep 5 # let the welcome page paint
qmp screendump "{\"filename\": \"$WORKDIR/welcome-window.ppm\"}" >/dev/null
echo "welcome screenshot: $WORKDIR/welcome-window.ppm"

echo "=== phase 1c: the shipped patch embeds our exact templates ==="
# The patch embeds the target files via repr(); the guest extracts them
# from the live ISO's patched main.py and compares hashes, so no bulk
# data crosses the (input-data-broken) channel in either direction.
flake_hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1]).read().replace("@@SYSTEM@@", sys.argv[2]).encode()).hexdigest())' "$TARGET_FLAKE" "$SYSTEM")
config_hash=$(sha256sum "$TARGET_CONFIG" | cut -d' ' -f1)
lock_hash=$(sha256sum "$(dirname "$0")/../iso/target/flake.lock" | cut -d' ' -f1)
guest_exec '
python3 - '"$flake_hash"' '"$config_hash"' '"$lock_hash"' <<'PYEOF'
import ast, glob, hashlib, os, sys
want = {"scoot_flake_text": sys.argv[1], "scoot_config_text": sys.argv[2], "scoot_lock_text": sys.argv[3]}
cands = glob.glob("/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py")
cands += glob.glob("/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py")
cands += glob.glob("/run/current-system/sw/share/calamares/modules/nixos/main.py")
print("main.py candidates:", cands)
if not cands:
    raise SystemExit("patched main.py not found in live store")
src = max((open(c).read() for c in cands), key=len)
def grab(name):
    for line in src.splitlines():
        s = line.strip()
        if s.startswith(name + " = "):
            rhs = s.split(" = ", 1)[1]
            if rhs[:1] == chr(39) or rhs[:1] == chr(34):
                return ast.literal_eval(rhs)
    raise SystemExit("template not found in shipped main.py: " + name)
for name, digest in want.items():
    got = hashlib.sha256(grab(name).encode()).hexdigest()
    assert got == digest, name + " hash mismatch: " + got + " != " + digest
    print(name + " hash OK: " + got)
print("EMBEDDING-OK")
PYEOF
'

echo "=== phase 2a: non-canonical hardware must refuse BEFORE partitioning (offline) ==="
# The static QEMU hardware the canonical install uses (byte-identical
# every run), read on the host: argv arrives intact, unlike bulk
# input-data. The tweak below derives from it the same way.
HW_CONTENT=$(cat "$TARGET_HARDWARE")
# The tweak: one extra initrd module in the generated hardware file,
# so the target closure is NOT the shipped reference (real hardware
# always differs this way). It rides argv like the static file (no
# single quotes anywhere); the installer-equivalence check below
# asserts the tweak toplevel actually differs, so a vacuous tweak
# fails loudly instead of passing silently.
TWEAK_HW="$(sed '$d' "$TARGET_HARDWARE")
  # fiso2 offline-refusal probe: non-canonical hardware, so the target
  # closure differs from the ISO-shipped reference.
  boot.initrd.availableKernelModules = [ \"btrfs\" ];
}"
# Render both flakes to /tmp (never /mnt: no disk is touched here),
# with the writer's own semantics for the canonical identity.
guest_exec "
python3 - '$TEST_USER' 'scoot' 'scoot' 'UTC' 'en_US.UTF-8' '25.11' '$SYSTEM' '$HW_CONTENT' '$TWEAK_HW' <<'PYEOF'
import ast, glob, os, sys
_, username, fullname, hostname, timezone, lang, nixosversion, system, hardware, tweak = sys.argv
cands = glob.glob('/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py')
cands += glob.glob('/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py')
cands += glob.glob('/run/current-system/sw/share/calamares/modules/nixos/main.py')
if not cands:
    raise SystemExit('patched main.py not found in live store')
src = max((open(c).read() for c in cands), key=len)
def grab(name):
    for line in src.splitlines():
        s = line.strip()
        if s.startswith(name + ' = '):
            rhs = s.split(' = ', 1)[1]
            if rhs[:1] == chr(39) or rhs[:1] == chr(34):
                return ast.literal_eval(rhs)
    raise SystemExit('template not found in shipped main.py: ' + name)
flake = grab('scoot_flake_text').replace('@@SYSTEM@@', system)
config = grab('scoot_config_text')
lock = grab('scoot_lock_text')
hm = grab('scoot_hm').replace('@@SCOOT_LOOK@@', 'moonrise')
users = grab('scoot_users')
scoot_vars = {'hostname': hostname, 'username': username, 'fullname': fullname, 'timezone': timezone, 'LANG': lang, 'nixosversion': nixosversion}
for _key, _val in scoot_vars.items():
    hm = hm.replace('@@' + _key + '@@', _val)
    users = users.replace('@@' + _key + '@@', _val)
config = config.replace('@@SCOOT_LOOK@@', 'moonrise')
config = config.replace('@@SCOOT_NH_FLAKE@@', '/home/' + username + '/nixos-config')
config = config.replace('  # @@TIMEZONE@@\n', '  time.timeZone = \"' + timezone + '\";\n')
config = config.replace('  # @@LOCALE@@\n', '  i18n.defaultLocale = \"' + lang + '\";\n')
config = config.replace('  # @@SCOOT_HM_USER@@', hm.rstrip(chr(10))).replace('  # @@SCOOT_USERS@@', users.rstrip(chr(10)))
for _key, _val in scoot_vars.items():
    config = config.replace('@@' + _key + '@@', _val)
assert '@@' not in config, 'unsubstituted marker left in rendered config'
assert '@@' not in flake, 'unsubstituted marker left in rendered flake'
for dest, hw in (('/tmp/canon-nixos-config', hardware), ('/tmp/tweak-nixos-config', tweak)):
    os.makedirs(dest, exist_ok=True)
    open(dest + '/flake.nix', 'w').write(flake)
    open(dest + '/configuration.nix', 'w').write(config)
    open(dest + '/flake.lock', 'w').write(lock)
    open(dest + '/hardware-configuration.nix', 'w').write(hw)
print('TWEAK-RENDER-OK')
PYEOF
"
# The installer's offline path, step for step: probe (network
# namespace emptied, so the substituters are unreachable), eval both
# toplevels, pre-flight each against the live store. Canonical must
# pass; the tweak must refuse with the missing-path message — all
# before sgdisk runs (asserted below: no vda partitions exist).
guest_exec "
unshare -n python3 - <<'PYEOF'
import os, re, subprocess, sys
def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)
probe_src = 'import urllib.request\nmode = \"offline\"\nfor u in (\"https://cache.nixos.org/nix-cache-info\", \"https://scoot-sh.cachix.org/nix-cache-info\"):\n    try:\n        urllib.request.urlopen(u, timeout=8).read(32)\n    except Exception:\n        continue\n    mode = \"online\"\n    break\nprint(mode)\n'
mode = sh(['python3', '-c', probe_src]).stdout.strip()
print('SCOOT-NETMODE:' + mode)
assert mode == 'offline', 'network cut did not isolate the probe (mode=' + mode + ')'
def toplevel(dest):
    r = sh(['nix', 'eval', '--offline', '--option', 'substitute', 'false', '--no-write-lock-file', '--raw', dest + '#nixosConfigurations.scoot.config.system.build.toplevel'])
    assert r.returncode == 0, 'offline eval failed for ' + dest + ': ' + (r.stderr or '')[-500:]
    return r.stdout.strip()
canon = toplevel('/tmp/canon-nixos-config')
tweak = toplevel('/tmp/tweak-nixos-config')
print('canon: ' + canon)
print('tweak: ' + tweak)
assert canon != tweak, 'TWEAK-NOCHANGE: the tweak toplevel equals canonical; pick a tweak that changes the closure'
print('TWEAK-DIFFERS-OK')
def preflight(dest, topo):
    r = sh(['nix', 'path-info', '-r', '--offline', topo])
    if r.returncode == 0:
        return [p for p in r.stdout.split() if not os.path.exists(p)]
    missing = [topo]
    try:
        dry = sh(['nix', 'build', '--dry-run', '--offline', '--option', 'substitute', 'false', '--no-link', dest + '#nixosConfigurations.scoot.config.system.build.toplevel'], timeout=300)
        for line in ((dry.stderr or '') + chr(10) + (dry.stdout or '')).splitlines():
            line = line.strip()
            if line.startswith('/nix/store/') and line.endswith('.drv'):
                try:
                    show = sh(['nix', 'derivation', 'show', line], timeout=120)
                    for out in re.findall(r'/nix/store/[a-z0-9]+-[^\"\\s]+', show.stdout or ''):
                        if out not in missing and not os.path.exists(out):
                            missing.append(out)
                except Exception:
                    pass
    except Exception:
        pass
    return missing
canon_missing = preflight('/tmp/canon-nixos-config', canon)
assert not canon_missing, 'canonical pre-flight should pass, missing: ' + str(canon_missing[:4])
print('CANON-PREFLIGHT-OK')
tweak_missing = preflight('/tmp/tweak-nixos-config', tweak)
assert tweak_missing, 'tweak pre-flight should refuse, but nothing is missing'
shown = ', '.join(sorted(tweak_missing)[:8])
if len(tweak_missing) > 8:
    shown += ' (and {} more)'.format(len(tweak_missing) - 8)
msg = 'OFFLINE-CLOSURE-INCOMPLETE: this hardware needs {} store paths that are not on the ISO ({}). Connect to the network and install again, or install on hardware matching the ISO.'.format(len(tweak_missing), shown)
print(msg)
assert 'connect to the network' in msg.lower(), 'message must name the remedy'
print('TWEAK-OFFLINE-REFUSAL-OK')
assert not os.path.exists('/dev/vda1'), 'disk was touched before the refusal (vda1 exists)'
print('DISK-UNTOUCHED-OK')
PYEOF
"
echo "=== phase 2b: unattended install, network cut ==="
guest_exec 'lsmod | grep -E "^(ext4|vfat)" || echo NO-FS-MODULES-LOADED; modprobe ext4 && echo MODPROBE-EXT4-OK || echo MODPROBE-EXT4-FAIL; modprobe vfat && echo MODPROBE-VFAT-OK || echo MODPROBE-VFAT-FAIL; grep -E "ext4|vfat" /proc/filesystems || echo NO-FS-IN-PROCFILESYS' || true
guest_exec 'sgdisk -Z /dev/vda && sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP /dev/vda && sgdisk -n 2:0:0 -t 2:8300 -c 2:root /dev/vda && partx -u /dev/vda && udevadm settle && lsblk -f /dev/vda && mkfs.fat -F32 /dev/vda1 && mkfs.ext4 -F /dev/vda2 && blkid /dev/vda1 /dev/vda2 && (mount /dev/vda2 /mnt || (dmesg | tail -25; blkid; exit 1)) && mkdir -p /mnt/boot && mount /dev/vda1 /mnt/boot && echo PARTITION-OK'
# Render the target files from the SHIPPED main.py's embedded templates
# (extracted exactly as the patch wrote them, then substituted with the
# writer's own semantics for the default choice: scoot-moonrise in the
# home folder for the CANONICAL user), into /mnt/home/<user>/nixos-config
# with /etc/nixos symlinked to it, committed to git and root-owned —
# byte for byte what the GUI writes (the installer hands the tree to
# the user only after a successful install). The hardware file is the
# static one the reference target imports (passed as an argv arg: argv
# arrives intact, unlike bulk input-data): nixos-generate-config output
# is non-deterministic (UUIDs, detected modules) and would break the
# closure match below. Then install with the guest network namespace
# emptied (unshare -n): any missing closure path fails here instead of
# phoning home.
# Canonical identity (must match nix/target-machine.nix exactly or the
# pre-copied closure below is a different system): user scoot,
# fullname scoot, host scoot, UTC, en_US.UTF-8, 25.11, moonrise.
# Render the installer's files into /mnt (writer semantics for the
# canonical identity), byte for byte what the GUI writes. $1 is the
# hardware nix text (canonical file, or the tweak for phase 4).
render_mnt_flake() {
guest_exec "
python3 - '$TEST_USER' 'scoot' 'scoot' 'UTC' 'en_US.UTF-8' '25.11' '$SYSTEM' '$1' <<'PYEOF'
import ast, glob, os, subprocess, sys
_, username, fullname, hostname, timezone, lang, nixosversion, system, hardware = sys.argv
cands = glob.glob('/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py')
cands += glob.glob('/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py')
cands += glob.glob('/run/current-system/sw/share/calamares/modules/nixos/main.py')
if not cands:
    raise SystemExit('patched main.py not found in live store')
src = max((open(c).read() for c in cands), key=len)
def grab(name):
    for line in src.splitlines():
        s = line.strip()
        if s.startswith(name + ' = '):
            rhs = s.split(' = ', 1)[1]
            if rhs[:1] == chr(39) or rhs[:1] == chr(34):
                return ast.literal_eval(rhs)
    raise SystemExit('template not found in shipped main.py: ' + name)
flake = grab('scoot_flake_text').replace('@@SYSTEM@@', system)
config = grab('scoot_config_text')
lock = grab('scoot_lock_text')
hm = grab('scoot_hm').replace('@@SCOOT_LOOK@@', 'moonrise')
users = grab('scoot_users')
scoot_vars = {'hostname': hostname, 'username': username, 'fullname': fullname, 'timezone': timezone, 'LANG': lang, 'nixosversion': nixosversion}
for _key, _val in scoot_vars.items():
    hm = hm.replace('@@' + _key + '@@', _val)
    users = users.replace('@@' + _key + '@@', _val)
config = config.replace('@@SCOOT_LOOK@@', 'moonrise')
config = config.replace('@@SCOOT_NH_FLAKE@@', '/home/' + username + '/nixos-config')
config = config.replace('  # @@TIMEZONE@@\n', '  time.timeZone = \"' + timezone + '\";\n')
config = config.replace('  # @@LOCALE@@\n', '  i18n.defaultLocale = \"' + lang + '\";\n')
config = config.replace('  # @@SCOOT_HM_USER@@', hm.rstrip(chr(10))).replace('  # @@SCOOT_USERS@@', users.rstrip(chr(10)))
for _key, _val in scoot_vars.items():
    config = config.replace('@@' + _key + '@@', _val)
assert '@@' not in config, 'unsubstituted marker left in rendered config'
assert '@@' not in flake, 'unsubstituted marker left in rendered flake'
flakedir = '/mnt/home/' + username + '/nixos-config'
os.makedirs(flakedir, exist_ok=True)
open(flakedir + '/flake.nix', 'w').write(flake)
open(flakedir + '/configuration.nix', 'w').write(config)
open(flakedir + '/flake.lock', 'w').write(lock)
open(flakedir + '/hardware-configuration.nix', 'w').write(hardware)
os.makedirs('/mnt/etc', exist_ok=True)
os.symlink('/home/' + username + '/nixos-config', '/mnt/etc/nixos')
subprocess.check_output(['git', '-C', flakedir, 'init', '-b', 'main'])
subprocess.check_output(['git', '-C', flakedir, 'add', '-A'])
subprocess.check_output(['git', '-C', flakedir, '-c', 'user.name=' + fullname, '-c', 'user.email=' + username + '@localhost', 'commit', '-m', 'Initial scoot system (scoot-iso installer)'])
print('RENDER-OK')
PYEOF
"
}
render_mnt_flake "$HW_CONTENT"
guest_exec "
set -e
ip -o link show | awk -F': ' '{print \$2}' | grep -v '^lo$' | while read -r ifc; do ip link set \"\$ifc\" down; done
ip -o link show
echo '--- installer-equivalent probe: the network is cut, so the shipped store is used ---'
python3 - <<'PYEOF' > /tmp/scoot-netmode.txt
import urllib.request
mode = \"offline\"
for u in (\"https://cache.nixos.org/nix-cache-info\", \"https://scoot-sh.cachix.org/nix-cache-info\"):
    try:
        urllib.request.urlopen(u, timeout=8).read(32)
    except Exception:
        continue
    mode = \"online\"
    break
print(mode)
PYEOF
mode=\$(cat /tmp/scoot-netmode.txt)
echo SCOOT-NETMODE:\$mode
[ \"\$mode\" = offline ] || { echo NETMODE-FAIL: expected offline with the network cut >&2; exit 1; }
echo '--- offline eval gate: the generated flake must resolve with no network and no substituters ---'
nix eval --offline --option substitute false --no-write-lock-file '/mnt/home/'$TEST_USER'/nixos-config#nixosConfigurations.scoot.config.system.build.toplevel.drvPath' && echo EVAL-OFFLINE-OK
echo '--- pre-flight: the target closure must already ride the ISO ---'
topo=\$(nix eval --offline --option substitute false --no-write-lock-file --raw '/mnt/home/'$TEST_USER'/nixos-config#nixosConfigurations.scoot.config.system.build.toplevel') && echo \"TOPLEVEL: \$topo\"
closure=\$(nix path-info -r --offline \"\$topo\") || { echo CLOSURE-PREFLIGHT-FAIL: target not on the ISO >&2; exit 1; }
missing=\$(for p in \$closure; do [ -e \"\$p\" ] || echo \"\$p\"; done)
[ -z \"\$missing\" ] || { echo \"OFFLINE-CLOSURE-INCOMPLETE: \$missing\" >&2; exit 1; }
echo CLOSURE-PREFLIGHT-OK
echo '--- archive: the build fetches flake inputs into the build store, which starts empty ---'
nix flake archive --to /mnt --offline --no-check-sigs '/mnt/home/'$TEST_USER'/nixos-config' && echo ARCHIVE-OK
echo '--- pre-copy: the target closure rides the ISO; copy it into the empty target store ---'
nix copy --to /mnt --no-check-sigs \"\$topo\" && echo PRECOPY-OK
unshare -n /bin/sh -c 'ip link set lo up; nixos-install --flake /mnt/home/$TEST_USER/nixos-config#scoot --root /mnt --no-root-passwd --no-write-lock-file --no-channel-copy --option build-dir /nix/var/nix/builds --option substitute false' > /tmp/install.log 2>&1
rc=\$?
echo INSTALL-RC:\$rc
tail -40 /tmp/install.log
ls -la /mnt/home/$TEST_USER/nixos-config/ /mnt/etc/nixos
exit \$rc
"
# Ownership handoff after a successful install (mirrors the installer's
# post-install step): the repo was committed root-owned so nix reads it
# as root, and only now becomes the user's.
guest_exec 'chown -R 1000:100 /mnt/home/'$TEST_USER' && echo CHOWN-OK'
guest_exec "nixos-enter --root /mnt -c \"echo '$TEST_USER:$TEST_PASS' | chpasswd\" && echo PASSWD-OK"
# poweroff kills the guest agent mid-command, which the qga helper
# reports as failure: tolerate it, the VM is down either way.
guest_exec 'poweroff || halt -p' || true
sleep 10
stop_vm

echo "=== phase 3: boot installed system, check greeter + session ==="
start_vm c
wait_ga
sleep 30 # ReGreet should be up
qmp screendump "{\"filename\": \"$WORKDIR/regreet.ppm\"}" >/dev/null
echo "greeter screenshot: $WORKDIR/regreet.ppm"
guest_exec 'systemctl is-active greetd && pgrep -af "[c]age|[r]egreet" | head -5 && echo GREETER-OK'
# Log in through ReGreet for real (HARD: the test fails here if login
# does not land). ReGreet 0.5 shows User+Session preselected with a
# Login button but no password field: clicking Login reveals it, and
# only then does typing the password + Enter log in. Keyboard-only
# send-key can never summon the field, so the click goes over the
# absolute pointer (usb-tablet above) via QMP input-send-event. (The
# virt board has no PS/2 keyboard either, so usb-kbd above is what the
# password typing lands on.)
# Coordinates are fractions of the 0..32767 absolute range, so any
# framebuffer size lands on the button (Login sits near (0.684w, 0.596h)
# at the 1280x800 virtio-gpu default, measured from the greeter
# screenshot; CI renders the same 1280x800 frame).
qmp_click() { # qmp_click <xfrac> <yfrac>
  local x y
  x=$(python3 -c "print(int(32767 * float('$1')))")
  y=$(python3 -c "print(int(32767 * float('$2')))")
  qmp input-send-event "{\"events\": [{\"type\": \"abs\", \"data\": {\"axis\": \"x\", \"value\": $x}}, {\"type\": \"abs\", \"data\": {\"axis\": \"y\", \"value\": $y}}, {\"type\": \"btn\", \"data\": {\"down\": true, \"button\": \"left\"}}]}" >/dev/null
  sleep 0.5
  qmp input-send-event '{"events": [{"type": "btn", "data": {"down": false, "button": "left"}}]}' >/dev/null
  sleep 1
}
# QMP send-key takes qcode names; password is [a-z0-9] by construction.
# One key per send-key call: a single call presses its whole key list
# as a chord, so typing means one call per character.
type_into_greeter() {
  local text="$1" ch key
  local i
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:$i:1}"
    case "$ch" in
      [0-9]) key="$ch" ;;
      [a-zA-Z]) key=$(printf '%s' "$ch" | tr 'A-Z' 'a-z') ;;
      -) key="minus" ;;
      =) key="equal" ;;
      /) key="slash" ;;
      ' ') key="spc" ;;
      *) echo "type_into_greeter: unsupported char $ch" >&2; return 1 ;;
    esac
    qmp send-key "{\"keys\": [{\"type\":\"qcode\",\"data\":\"$key\"}], \"hold-time\": 50}" >/dev/null
    sleep 0.3
  done
  sleep 1
}
# session_up: the real login landed (the user's scoot owns an IPC
# socket and its service runs under the user manager).
session_up() {
  guest_exec 'ls /run/user/1000/scoot.sock >/dev/null 2>&1 && sudo -u '$TEST_USER' env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active scoot.service >/dev/null 2>&1 && echo SESSION-UP' 2>/dev/null | grep -q SESSION-UP
}
attempt_login() {
  # Escape first: returns a half-typed prompt to the user-select state,
  # so a retry never appends a full password to a partial one.
  qmp send-key '{"keys": [{"type":"qcode","data":"esc"}], "hold-time": 50}' >/dev/null
  sleep 2
  qmp_click 0.684 0.596 # Login: reveals the password field
  sleep 4
  type_into_greeter "$TEST_PASS"
  qmp send-key '{"keys": [{"type":"qcode","data":"ret"}], "hold-time": 50}' >/dev/null
}
echo "=== phase 3a: log in through ReGreet (hard) ==="
attempt_login
login_ok=0
for _ in $(seq 1 12); do
  if session_up; then login_ok=1; break; fi
  sleep 5
done
if [ "$login_ok" != 1 ]; then
  echo "login attempt 1 missed; clicking Login again and retyping"
  qmp screendump "{\"filename\": \"$WORKDIR/login-retry.ppm\"}" >/dev/null || true
  attempt_login
  for _ in $(seq 1 12); do
    if session_up; then login_ok=1; break; fi
    sleep 5
  done
fi
if [ "$login_ok" != 1 ]; then
  echo "LOGIN-FAIL: no user session after two ReGreet attempts" >&2
  qmp screendump "{\"filename\": \"$WORKDIR/login-failure.ppm\"}" >/dev/null || true
  guest_exec 'loginctl list-sessions || true; pgrep -au 1000 | head -10 || true; systemctl status greetd --no-pager | head -20 || true'
  exit 1
fi
echo "LOGIN-OK: real ReGreet login as $TEST_USER"
sleep 5 # let bar + wallpaper settle
qmp screendump "{\"filename\": \"$WORKDIR/installed-session.ppm\"}" >/dev/null
echo "installed session screenshot: $WORKDIR/installed-session.ppm"

echo "=== phase 3b: the installed flake is normal and maintainable ==="
# The installer wrote ~/nixos-config (home default) with /etc/nixos
# symlinked to it. Prove it: ownership, the git repo, a github-pinned
# lock with no path: overrides, then rebuild offline two ways
# (nixos-rebuild and nh, network namespace emptied).
guest_exec '
echo "--- flake home ---"
ls -lad /etc/nixos /home/'$TEST_USER'/nixos-config
test -L /etc/nixos && echo SYMLINK-OK
stat -c "%U %G %a %n" /home/'$TEST_USER'/nixos-config /home/'$TEST_USER'/nixos-config/flake.nix
echo "--- git repo (as the owner: root reads hit libgit2 ownership) ---"
sudo -u '$TEST_USER' git -C /home/'$TEST_USER'/nixos-config log --oneline
sudo -u '$TEST_USER' git -C /home/'$TEST_USER'/nixos-config status --short
echo "--- flake files ---"
cat /home/'$TEST_USER'/nixos-config/flake.nix
echo "--- lock inputs (no python3 on the target: grep) ---"
grep -o "\"type\": \"[a-z]*\"" /home/'$TEST_USER'/nixos-config/flake.lock | sort | uniq -c
grep -o "\"rev\": \"[a-f0-9]*\"" /home/'$TEST_USER'/nixos-config/flake.lock
! grep -q "path:/nix/store" /home/'$TEST_USER'/nixos-config/flake.lock && echo LOCK-OK
'
echo "=== phase 3c: prove the REAL logged-in session (hard) ==="
# No headless stand-in: these run against the session the ReGreet login
# above started, as the installed user. Any failure exits the test.
guest_exec '
set -e
export XDG_RUNTIME_DIR=/run/user/1000
export SCOOT_SOCKET=$XDG_RUNTIME_DIR/scoot.sock
test -S "$SCOOT_SOCKET" && echo SOCKET-OK
echo "--- compositor IPC from inside the session ---"
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg version" && echo MSG-VERSION-OK
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg outputs" | tee /tmp/outputs.txt && echo MSG-OUTPUTS-OK
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg windows" && echo MSG-WINDOWS-OK
'
echo "--- the bar reserves space (usable vs rect) ---"
# NOTE: no python3 on the target (like phase 3b, the guest stays
# grep-grade): the outputs JSON is validated on the HOST, where
# python3 is guaranteed. tail drops the helper's "rc:" status line.
guest_exec 'cat /tmp/outputs.txt' | tail -n +2 > "$WORKDIR/outputs.json"
python3 - "$WORKDIR/outputs.json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
# The reply is the internally-tagged Response envelope
# ({"type": "outputs", "outputs": [...]}); accept a bare list too.
outputs = data.get("outputs", data) if isinstance(data, dict) else data
assert outputs, "no outputs reported"
for o in outputs:
    rect, usable = o["rect"], o["usable"]
    print("output:", o.get("name"), "rect:", rect, "usable:", usable)
    assert usable["height"] < rect["height"], "bar reserves no space: usable == rect"
print("BAR-SPACE-OK")
EOF
guest_exec '
set -e
export XDG_RUNTIME_DIR=/run/user/1000
export SCOOT_SOCKET=$XDG_RUNTIME_DIR/scoot.sock
echo "--- the installed bar wears the look layout, not the clock-only default ---"
grep -q "workspaces" /etc/scootbar/bar.toml && grep -q "window-title" /etc/scootbar/bar.toml && grep -q "^\[clock\]" /etc/scootbar/bar.toml && echo BAR-CONTENT-OK
! grep -q "welcome" /etc/scootbar/bar.toml && echo BAR-NO-WELCOME-OK
echo "--- bar + wallpaper resident ---"
pgrep -u 1000 -x scootbar && echo BAR-PROC-OK
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active scootbar" && echo BAR-UNIT-OK
# Full-command match (the daemon comm is the .scootbg-wrapped binary,
# not "scootbg"): the bracket dodges pgrep matching our own sh -c line.
pgrep -u 1000 -f '[s]cootbg-wrapped' && echo BG-PROC-OK
echo "--- the compositor'"'"'s own screenshot path ---"
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET timeout 120 scoot msg screenshot --out /tmp/installed-scoot.png" && echo SCREENSHOT-OK
echo MSG-OK
'
# Pull the IPC screenshot back to the host for the artifacts, in SMALL
# pieces: only small guest->host payloads are proven on this channel,
# so 32K chunks (base64 ~44K each) stay far under the ~100K size where
# the old loop's reassembled PNGs truncated. The loop runs until the
# first missing piece and then requires the reassembled bytes to equal
# the guest's byte count exactly: a short fetch fails the test.
guest_exec 'stat -c%s /tmp/installed-scoot.png && split -b 32768 -d /tmp/installed-scoot.png /tmp/shot_ && echo SPLIT-OK'
want=$(guest_exec 'stat -c%s /tmp/installed-scoot.png' | tail -1)
echo "guest screenshot bytes: $want"
: > "$WORKDIR/shot-parts.b64"
pieces=0
while [ "$pieces" -lt 100 ]; do
  frag=$(printf '/tmp/shot_%02d' "$pieces")
  out=$(guest_exec "test -f $frag && base64 -w0 $frag || echo MISSING") || { echo "PNG-FETCH-FAIL: guest-exec failed on $frag" >&2; exit 1; }
  body=$(printf '%s' "$out" | grep -v '^rc:' || true)
  if [ "$body" = "MISSING" ]; then break; fi
  # One piece per line: base64 chunks carry their own padding, and a
  # decoder fed the raw concatenation stops at the first chunk's `=`
  # (that truncation is what the old loop shipped). The validator
  # decodes line by line and requires the exact guest byte count.
  printf '%s\n' "$body" >> "$WORKDIR/shot-parts.b64"
  pieces=$((pieces + 1))
done
[ "$pieces" -gt 0 ] || { echo "PNG-FETCH-FAIL: no pieces fetched" >&2; exit 1; }
python3 - "$WORKDIR/shot-parts.b64" "$WORKDIR/installed-scoot.png" "$want" <<'EOF'
import base64, sys
parts = open(sys.argv[1]).read().split()
raw = b"".join(base64.b64decode(p) for p in parts)
assert raw[:8] == b"\x89PNG\r\n\x1a\n", "reassembled bytes are not a PNG"
want = int(sys.argv[3])
assert len(raw) == want, f"truncated fetch: reassembled {len(raw)} != guest {want}"
open(sys.argv[2], "wb").write(raw)
print(f"screenshot saved: {sys.argv[2]} ({len(raw)} bytes in {len(parts)} pieces, complete)")
EOF
echo "PNG-OK"
echo "=== phase 3e: offline rebuilds on the installed system ==="
# The network namespace is emptied, so success proves the store holds
# everything a maintainable flake needs; the lock hash before/after
# proves neither rebuild rewrote it. Both rebuilds run as the flake
# owner (root hits libgit2 ownership on a user-owned flake): the build
# from /tmp (the result link needs a writable cwd) and nh, which
# refuses root and escalates itself (sudo pre-authed with the test
# password). nh switches last (it re-activates).
guest_exec "
lock_before=\$(sha256sum /home/$TEST_USER/nixos-config/flake.lock)
ip link show | awk -F': ' '{print \$2}' | grep -v '^lo\$' | while read -r ifc; do ip link set \"\$ifc\" down; done
fail=0
unshare -n /bin/sh -c 'ip link set lo up; su -s /bin/sh $TEST_USER -c \"cd /tmp && nixos-rebuild build --flake /etc/nixos#scoot\"' && echo REBUILD-OK || fail=1
unshare -n /bin/sh -c 'ip link set lo up; su -s /bin/sh $TEST_USER -c \"echo $TEST_PASS | sudo -S true && NH_FLAKE=/home/$TEST_USER/nixos-config nh os switch\"' && echo NH-OK || fail=1
lock_after=\$(sha256sum /home/$TEST_USER/nixos-config/flake.lock)
echo \"lock before: \$lock_before\"
echo \"lock after:  \$lock_after\"
[ \"\$lock_before\" = \"\$lock_after\" ] && echo LOCK-STABLE-OK || fail=1
grep -o '\"rev\": \"[a-f0-9]*\"' /home/$TEST_USER/nixos-config/flake.lock
exit \$fail
"
if [ "$ONLINE_TWEAK" = 1 ]; then
echo "=== phase 4: the same tweak installs WITH the network up ==="
# The installed disk is bootable now, but phase 4 must boot the ISO,
# not the disk. The disk's proofs are all saved on the host, and
# phase 4 wipes it anyway: zero both GPT ends (primary header plus
# the backup table the firmware would otherwise fall back to) with
# base tools only — no mounts, no NVRAM edits — verify the magic is
# gone at both ends, then boot the ISO on a FRESH vars file (the
# reused one carries NVRAM BootOrder entries), and assert the ISO
# boot before touching anything.
guest_exec '
set -e
size=$(blockdev --getsz /dev/vda)
dd if=/dev/zero of=/dev/vda bs=1M count=64 conv=fsync
dd if=/dev/zero of=/dev/vda bs=1M seek=$((size / 2048 - 64)) count=64 conv=fsync
sync
! dd if=/dev/vda bs=512 count=2 2>/dev/null | grep -q "EFI PART" || { echo UNBOOT-VERIFY-FAIL >&2; exit 1; }
! dd if=/dev/vda bs=512 skip=$((size - 1)) count=1 2>/dev/null | grep -q "EFI PART" || { echo UNBOOT-VERIFY-FAIL >&2; exit 1; }
echo DISK-UNBOOTED-OK
'
cp "$OVMF_VARS_SRC" "$WORKDIR/OVMF_VARS_4.fd" && chmod u+w "$WORKDIR/OVMF_VARS_4.fd"
VARS="$WORKDIR/OVMF_VARS_4.fd"
stop_vm
start_vm d
wait_ga
guest_exec 'test -d /etc/scoot-welcome && echo ISO-BOOT-OK'
# The fresh live boot needs a moment before its system tools resolve:
# wait_ga only proves the agent is up, and partitioning immediately
# after it raced activation (sgdisk not yet on PATH).
for _ in $(seq 1 30); do
  if guest_exec 'for t in sgdisk mkfs.fat mkfs.ext4 nix nixos-install; do command -v "$t" >/dev/null || exit 1; done && echo TOOLS-UP' 2>/dev/null | grep -q TOOLS-UP; then break; fi
  sleep 10
done
guest_exec 'for t in sgdisk mkfs.fat mkfs.ext4 nix nixos-install; do command -v "$t" >/dev/null || exit 1; done && echo TOOLS-UP'
guest_exec 'sgdisk -Z /dev/vda && sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP /dev/vda && sgdisk -n 2:0:0 -t 2:8300 -c 2:root /dev/vda && partx -u /dev/vda && udevadm settle && mkfs.fat -F32 /dev/vda1 && mkfs.ext4 -F /dev/vda2 && mount /dev/vda2 /mnt && mkdir -p /mnt/boot && mount /dev/vda1 /mnt/boot && echo TWEAK-PARTITION-OK'
render_mnt_flake "$TWEAK_HW"
guest_exec "
set -e
echo '--- installer-equivalent probe: the network is up ---'
python3 - <<'PYEOF' > /tmp/scoot-netmode.txt
import urllib.request
mode = \"offline\"
for u in (\"https://cache.nixos.org/nix-cache-info\", \"https://scoot-sh.cachix.org/nix-cache-info\"):
    try:
        urllib.request.urlopen(u, timeout=8).read(32)
    except Exception:
        continue
    mode = \"online\"
    break
print(mode)
PYEOF
mode=\$(cat /tmp/scoot-netmode.txt)
echo SCOOT-NETMODE:\$mode
[ \"\$mode\" = online ] || { echo NETMODE-FAIL: expected online with the network up >&2; exit 1; }
echo TWEAK-NETMODE-ONLINE-OK
tweak_topo=\$(nix eval --no-write-lock-file --raw '/mnt/home/'$TEST_USER'/nixos-config#nixosConfigurations.scoot.config.system.build.toplevel') && echo \"TWEAK-TOPLEVEL: \$tweak_topo\"
[ ! -e \"\$tweak_topo\" ] || { echo TWEAK-NOCHANGE-FAIL: tweak toplevel already on the ISO >&2; exit 1; }
echo \"pre-copying what the ISO already ships (the tweak delta comes over the network)\"
tweak_drv=\$(nix eval --no-write-lock-file --raw '/mnt/home/'$TEST_USER'/nixos-config#nixosConfigurations.scoot.config.system.build.toplevel.drvPath')
nix-store --query --requisites --include-outputs \"\$tweak_drv\" 2>/dev/null | grep -v '\.drv\$' > /tmp/tweak-wanted.txt || true
: > /tmp/tweak-have.txt
while read -r p; do [ -e \"\$p\" ] && echo \"\$p\" >> /tmp/tweak-have.txt; done < /tmp/tweak-wanted.txt
wc -l /tmp/tweak-wanted.txt /tmp/tweak-have.txt
xargs -a /tmp/tweak-have.txt nix copy --to /mnt --no-check-sigs && echo TWEAK-PRECOPY-OK || echo TWEAK-PRECOPY-SKIP
nixos-install --flake /mnt/home/$TEST_USER/nixos-config#scoot --root /mnt --no-root-passwd --no-write-lock-file --no-channel-copy --option build-dir /nix/var/nix/builds > /tmp/install-tweak.log 2>&1
rc=\$?
echo TWEAK-INSTALL-RC:\$rc
tail -20 /tmp/install-tweak.log
[ -e \"/mnt\$tweak_topo\" ] && echo TWEAK-FROM-NETWORK-OK
exit \$rc
"
guest_exec 'chown -R 1000:100 /mnt/home/'$TEST_USER' && echo TWEAK-CHOWN-OK'
guest_exec "nixos-enter --root /mnt -c \"echo '$TEST_USER:$TEST_PASS' | chpasswd\" && echo TWEAK-PASSWD-OK"
guest_exec 'poweroff || halt -p' || true
sleep 10
stop_vm
echo "=== phase 4b: the tweak install boots and logs in ==="
start_vm c
wait_ga
# KVM can lag cage: the greeter procs are up long before the first
# frame hits the framebuffer (CI's screendumps caught blank displays
# while GREETER-OK passed). Poll the frame itself for content before
# clicking: a uniform frame is not ready, a varied one is. Never fail
# here — the login attempts below stay the hard gate.
qmp_ready() { # $1 = ppm path; echoes READY or NOT-READY
  python3 - "$1" <<'EOF'
import sys
try:
    p = open(sys.argv[1], "rb").read()
    assert p[:2] == b"P6"
    i = p.rfind(b"\n255\n")
    assert i > 0
    raw = p[i + 5:]
    samp = raw[:: max(1, len(raw) // 3000)]
    print("READY" if len(set(samp)) > 64 else "NOT-READY")
except Exception:
    print("NOT-READY")
EOF
}
ready=0
for _ in $(seq 1 24); do
  qmp screendump "{\"filename\": \"$WORKDIR/tweak-session.ppm\"}" >/dev/null 2>&1 || true
  if [ "$(qmp_ready "$WORKDIR/tweak-session.ppm")" = READY ]; then ready=1; break; fi
  sleep 10
done
[ "$ready" = 1 ] && echo TWEAK-DISPLAY-READY || echo "TWEAK-DISPLAY-WARN: framebuffer stayed uniform; attempting login anyway"
guest_exec 'systemctl is-active greetd && echo TWEAK-GREETER-OK'
attempt_login
login_ok=0
for _ in $(seq 1 12); do
  if session_up; then login_ok=1; break; fi
  sleep 5
done
if [ "$login_ok" != 1 ]; then
  echo "login attempt 1 missed; clicking Login again and retyping"
  qmp screendump "{\"filename\": \"$WORKDIR/tweak-login-retry.ppm\"}" >/dev/null || true
  attempt_login
  for _ in $(seq 1 12); do
    if session_up; then login_ok=1; break; fi
    sleep 5
  done
fi
if [ "$login_ok" != 1 ]; then
  echo "TWEAK-LOGIN-FAIL: no user session after the online tweak install" >&2
  qmp screendump "{\"filename\": \"$WORKDIR/tweak-login-failure.ppm\"}" >/dev/null || true
  guest_exec 'loginctl list-sessions || true; pgrep -au 1000 | head -10 || true; systemctl status greetd --no-pager | head -20 || true'
  exit 1
fi
echo "TWEAK-ONLINE-LOGIN-OK: tweak install boots and logs in with the network path"
guest_exec '
export XDG_RUNTIME_DIR=/run/user/1000
export SCOOT_SOCKET=$XDG_RUNTIME_DIR/scoot.sock
su -s /bin/sh '$TEST_USER' -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg version" && echo TWEAK-MSG-OK
'
guest_exec 'poweroff || halt -p' || true
sleep 10
stop_vm
else
echo "ONLINE-TWEAK-SKIPPED (QEMU_TEST_ONLINE_TWEAK=0: only the offline half is proven)"
fi
# Convert QMP's PPM screendumps to PNG for the workflow artifacts and
# the README (stdlib only; idempotent, so the workflow's fallback step
# re-running it after a failure is harmless).
python3 "$(dirname "$0")/ppm-to-png.py" "$WORKDIR"
echo "=== qemu-test done; artifacts in $WORKDIR ==="
