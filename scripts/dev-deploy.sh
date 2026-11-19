#!/usr/bin/env bash
# Dev loop for performance work: build the patched KytyPS5 on a PC and swap it
# onto a PS4 that is running EmuFive, over SSH. Run from the EmuFive checkout
# (inside WSL's own filesystem, not /mnt/c).
#
#   scripts/dev-deploy.sh PS4_IP              build, then install on the PS4
#   scripts/dev-deploy.sh PS4_IP --no-build   install the last build
#   scripts/dev-deploy.sh PS4_IP --restore    put the release binary back
#   scripts/dev-deploy.sh PS4_IP --perf on    turn the perf log on (off: off)
#   scripts/dev-deploy.sh PS4_IP --log        copy ~/kytyps5.log to out/logs/
#
# Needs SSH login turned on in EmuFive (Settings). Run `ssh-copy-id ps5@PS4_IP`
# once so only sudo asks for the password (ps5 unless you changed it).
# The installed binary is not stripped, so `perf report` can name functions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/kytyps5/_Build/ps4/kyty_emulator"
DEST=/opt/kytyps5/kyty_emulator

log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 PS4_IP [--no-build|--restore|--perf on|off|--log]"
PS4="$1"; shift
TARGET="ps5@$PS4"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
remote()      { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
remote_sudo() { ssh -t "${SSH_OPTS[@]}" "$TARGET" "$@"; }   # -t: sudo can ask for the password

install_binary() {
    [ -x "$BIN" ] || die "no build at $BIN (run without --no-build first)"
    local id
    id="$(cd "$ROOT/patches/kytyps5" && cat ./*.patch | sha256sum | cut -c1-8)"
    log "Copying kyty_emulator ($(du -h "$BIN" | cut -f1), patches $id) to $PS4"
    scp "${SSH_OPTS[@]}" -q "$BIN" "$TARGET:/tmp/kyty_emulator.new"
    remote_sudo "set -e
        [ -e $DEST.release ] || sudo cp -a $DEST $DEST.release
        sudo install -m 755 /tmp/kyty_emulator.new $DEST
        rm -f /tmp/kyty_emulator.new
        echo $id | sudo tee /opt/kytyps5/DEV-BUILD > /dev/null"
    ok "Installed (patches $id). Start the game from the home screen; the release binary is $DEST.release"
}

case "${1:-}" in
    "")
        KYTY_ARCH=btver2 "$ROOT/scripts/build-kyty.sh"
        install_binary ;;
    --no-build)
        install_binary ;;
    --restore)
        remote_sudo "set -e
            [ -e $DEST.release ] || { echo 'no release binary saved'; exit 1; }
            sudo install -m 755 $DEST.release $DEST
            sudo rm -f /opt/kytyps5/DEV-BUILD"
        ok "Release binary restored" ;;
    --perf)
        case "${2:-}" in
            on)  remote "mkdir -p ~/.kytyps5 && touch ~/.kytyps5/perf-log" && ok "Perf log on (from the next game start)" ;;
            off) remote "rm -f ~/.kytyps5/perf-log" && ok "Perf log off" ;;
            *)   die "--perf on or --perf off" ;;
        esac ;;
    --log)
        mkdir -p "$ROOT/out/logs"
        out="$ROOT/out/logs/kytyps5-$(date +%Y%m%d-%H%M%S).log"
        scp "${SSH_OPTS[@]}" -q "$TARGET:kytyps5.log" "$out"
        build="$(remote 'cat /opt/kytyps5/DEV-BUILD 2>/dev/null || echo release')"
        ok "$out (binary: $build)"
        perf_lines="$(grep -c 'Perf flips [0-9]*:' "$out" || true)"
        if [ "$perf_lines" -gt 0 ]; then
            log "FPS over $perf_lines samples (min / median / max):"
            grep -o 'Perf flips [0-9]*: [0-9.]* fps' "$out" | awk '{print $4}' | sort -n |
                awk '{a[NR]=$1} END {printf "    %.1f / %.1f / %.1f\n", a[1], a[int((NR+1)/2)], a[NR]}'
        fi ;;
    *)
        die "unknown option: $1" ;;
esac
