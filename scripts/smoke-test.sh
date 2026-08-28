#!/bin/bash
# smoke-test.sh -- install the packages into a throwaway root and prove the
# server and every module actually work.
#
# This deliberately tests both supported install shapes, because "the RPM
# built" and "the module loads" are different claims:
#
#   redis        plain server. Only vector sets (compiled into redis-server).
#                Every module command must be REJECTED -- that is what proves
#                a plain install really is plain.
#   redis-full   server plus all four modules, all commands working.
#
# Usage:
#   scripts/smoke-test.sh copr [<chroot>]    install from the Copr repo
#   scripts/smoke-test.sh local <dir>        install from a local rpm dir
#
# Exits non-zero on the first failed assertion.

set -uo pipefail

MODE="${1:-copr}"
ARG="${2:-}"
ARCH=$(uname -m)
CHROOT="${CHROOT:-fedora-43-$ARCH}"
# /tmp is often a small tmpfs; a full install root does not fit there.
ROOT_BASE="${ROOT_BASE:-$HOME/.cache/redis-smoke}"
# Install roots are root-owned, so server logs go somewhere this user can write.
LOGDIR="${LOGDIR:-$ROOT_BASE/logs}"
PORT="${PORT:-7890}"
FAILED=0

case "$MODE" in
  copr)
    [ -n "$ARG" ] && CHROOT="$ARG"
    REPO_URL="https://download.copr.fedorainfracloud.org/results/@redis/redis/${CHROOT}/"
    DNF_REPO="--repofrompath=smoke,$REPO_URL --setopt=smoke.gpgcheck=0"
    echo "==> source: Copr $CHROOT"
    ;;
  local)
    [ -z "$ARG" ] && { echo "usage: $0 local <dir-with-rpms>"; exit 2; }
    ARG="$(cd "$ARG" && pwd)"
    command -v createrepo_c >/dev/null || { echo "createrepo_c not installed"; exit 2; }
    createrepo_c "$ARG" >/dev/null 2>&1
    DNF_REPO="--repofrompath=smoke,file://$ARG --setopt=smoke.gpgcheck=0"
    echo "==> source: local $ARG"
    ;;
  *) echo "usage: $0 {copr [chroot]|local <dir>}"; exit 2 ;;
esac

ok()   { printf '    \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '    \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED+1)); }

# assert_cmd <desc> <expected-substring> <redis-cli args...>
# Matches against the first reply line -- right for scalar replies.
assert_cmd() {
    local desc="$1" want="$2"; shift 2
    local got; got=$($CLI "$@" 2>&1 | head -1)
    case "$got" in
        *"$want"*) ok "$desc  ($got)" ;;
        *)         bad "$desc  expected '$want', got '$got'" ;;
    esac
}

# assert_reply <desc> <expected-substring> <redis-cli args...>
# Matches anywhere in a multi-line reply. FT.SEARCH needs this: its first
# line is the result count, and the matching key comes after it.
assert_reply() {
    local desc="$1" want="$2"; shift 2
    local got; got=$($CLI "$@" 2>&1 | tr '\n' ' ')
    case "$got" in
        *"$want"*) ok "$desc  ($(echo "$got" | cut -c1-60))" ;;
        *)         bad "$desc  expected '$want', got '$got'" ;;
    esac
}

install_root() {
    local pkg="$1" root="$2"
    sudo rm -rf "$root"; mkdir -p "$(dirname "$root")"
    sudo dnf -q -y --installroot="$root" --releasever="${CHROOT#fedora-}" \
        --releasever="$(echo "$CHROOT" | cut -d- -f2)" --use-host-config \
        $DNF_REPO --refresh install "$pkg" >/dev/null 2>&1
}

start_server() {
    local root="$1"
    sudo tee "$root/smoke.conf" >/dev/null <<EOF
port $PORT
daemonize no
logfile ""
dir /tmp
# Some CI hosts trip Redis's ARM64 copy-on-write check; it is unrelated to
# packaging and would otherwise abort startup.
ignore-warnings ARM64-COW-BUG
include /etc/redis/modules/*.conf
EOF
    mkdir -p "$LOGDIR"
    LOG="$LOGDIR/$(basename "$root").log"
    sudo chroot "$root" /usr/bin/env LC_ALL=C LANG=C \
        /usr/bin/redis-server /smoke.conf >"$LOG" 2>&1 &
    CLI="sudo chroot $root /usr/bin/redis-cli -p $PORT"
    for _ in $(seq 30); do
        [ "$($CLI PING 2>/dev/null)" = "PONG" ] && return 0
        sleep 1
    done
    echo "    server did not come up; log:"; tail -8 "$LOG" 2>/dev/null | sed 's/^/      /'
    return 1
}

stop_server() { $CLI SHUTDOWN NOSAVE >/dev/null 2>&1; sleep 1; }

# ---------------------------------------------------------------------------
echo
echo "=== 1/2  dnf install redis  (plain server) ==="
ROOT="$ROOT_BASE/plain"
install_root redis "$ROOT" || { echo "install failed"; exit 1; }
echo "  installed: $(sudo rpm --root="$ROOT" -qa 2>/dev/null | grep -cE '^redis') redis package(s)"
sudo rpm --root="$ROOT" -qa 2>/dev/null | grep -E '^redis' | sort | sed 's/^/    /'
if start_server "$ROOT"; then
    assert_cmd "server responds"            "PONG"     PING
    assert_cmd "vector sets built in"       "1"        VADD vs VALUES 3 1 2 3 e1
    # The point of a plain install: module commands must NOT exist.
    assert_cmd "no RedisJSON"               "unknown command" JSON.SET d . '{"a":1}'
    assert_cmd "no RedisBloom"              "unknown command" BF.ADD f x
    assert_cmd "no RedisTimeSeries"         "unknown command" TS.ADD t 1 1
    assert_cmd "no RediSearch"              "unknown command" FT.CREATE i ON HASH PREFIX 1 k: SCHEMA t TEXT
    stop_server
else FAILED=$((FAILED+1)); fi
sudo rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo
echo "=== 2/2  dnf install redis-full  (server + all modules) ==="
ROOT="$ROOT_BASE/full"
install_root redis-full "$ROOT" || { echo "install failed"; exit 1; }
sudo rpm --root="$ROOT" -qa 2>/dev/null | grep -E '^redis' | sort | sed 's/^/    /'
if start_server "$ROOT"; then
    echo "  modules: $($CLI MODULE LIST 2>/dev/null | paste - - - - - - - - 2>/dev/null | awk '{printf "%s ", $2}')"
    assert_cmd "server responds"     "PONG" PING
    assert_cmd "vector sets"         "1"    VADD vs VALUES 3 1 2 3 e1
    assert_cmd "RedisJSON  JSON.SET" "OK"   JSON.SET doc . '{"n":"fedora","t":[1,2,3]}'
    assert_cmd "RedisJSON  JSON.GET" "fedora" JSON.GET doc .n
    assert_cmd "RedisBloom BF.ADD"   "1"    BF.ADD filt hello
    assert_cmd "RedisBloom BF.EXISTS" "1"   BF.EXISTS filt hello
    assert_cmd "RedisBloom absent key" "0"  BF.EXISTS filt nope
    assert_cmd "RedisTS    TS.CREATE" "OK"  TS.CREATE temp RETENTION 3600
    assert_cmd "RedisTS    TS.ADD"    "1000" TS.ADD temp 1000 22.5
    assert_cmd "RediSearch FT.CREATE" "OK"  FT.CREATE idx ON HASH PREFIX 1 item: SCHEMA title TEXT price NUMERIC
    $CLI HSET item:1 title "fedora rpm packaging" price 10 >/dev/null 2>&1
    sleep 1
    assert_reply "RediSearch FT.SEARCH" "item:1" FT.SEARCH idx fedora
    stop_server
else FAILED=$((FAILED+1)); fi
sudo rm -rf "$ROOT"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "=== ALL SMOKE TESTS PASSED ==="; exit 0
else
    echo "=== $FAILED CHECK(S) FAILED ==="; exit 1
fi
