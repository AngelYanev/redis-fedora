#!/bin/bash
# make-sources.sh -- regenerate every generated Source for redis.spec.
#
# Three of the Sources cannot be downloaded from a URL, because they do not
# exist as upstream release artefacts:
#
#   Source0  redis-<ver>-full.tar.gz        upstream `make tarball`: Redis core
#                                           plus every module at the ref pinned
#                                           in modules/modules.yaml
#   Source1  redisjson-vendor-<ver>.tar.gz  `cargo vendor` of RedisJSON
#   Source2  redisearch-vendor-<ver>.tar.gz `cargo vendor` of RediSearch
#
# All three need network access, so they are produced here and shipped inside
# the SRPM -- the buildroot itself is offline.
#
# Sources 3-8 (RediSearch's CMake FetchContent deps) DO have upstream URLs and
# are fetched with spectool by the Makefile's `download` target.
#
# Usage:  scripts/make-sources.sh [<redis-tag>]
#         defaults to the Version: in redis.spec

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SPEC="$REPO_ROOT/redis.spec"
OUTDIR="${OUTDIR:-$(rpm --eval %{_sourcedir})}"
WORK="${WORK:-$HOME/.cache/redis-sources}"

TAG="${1:-$(awk '/^Version:/{print $2; exit}' "$SPEC")}"
JSON_VER=$(awk '/^%global json_ver/{print $3; exit}' "$SPEC")
SEARCH_VER=$(awk '/^%global search_ver/{print $3; exit}' "$SPEC")

echo "==> redis tag       : $TAG"
echo "==> redisjson ver   : $JSON_VER"
echo "==> redisearch ver  : $SEARCH_VER"
echo "==> output          : $OUTDIR"
mkdir -p "$OUTDIR" "$WORK"

# ---------------------------------------------------------------------------
# Source0 -- Redis core + all modules, via upstream's own tarball target.
# ---------------------------------------------------------------------------
CLONE="$WORK/redis"
if [ ! -d "$CLONE/.git" ]; then
    echo "==> cloning redis/redis"
    git clone --quiet https://github.com/redis/redis "$CLONE"
fi
git -C "$CLONE" fetch --quiet --tags origin
git -C "$CLONE" checkout --quiet "$TAG"

echo "==> make modules-update (clones each module at its modules.yaml ref)"
( cd "$CLONE" && MODULES_UPDATE_SHALLOW=1 make modules-update all >/dev/null )

echo "==> make tarball"
( cd "$CLONE" && TARBALL_SKIP_MODULES_UPDATE=1 make tarball \
      TAG="$TAG" OUT_PATH="$OUTDIR/redis-$TAG-full.tar.gz" >/dev/null )

# ---------------------------------------------------------------------------
# Source1 -- RedisJSON vendored crates.
# The spec expects a `vendor/` directory that also contains
# vendor/.cargo/config.toml, which plain `cargo vendor` does not write.
# ---------------------------------------------------------------------------
echo "==> cargo vendor: redisjson"
JDIR="$WORK/redisjson-$JSON_VER"
rm -rf "$JDIR" && cp -a "$CLONE/modules/redisjson/src" "$JDIR"
( cd "$JDIR"
  rm -rf vendor .cargo
  cargo vendor vendor > "$WORK/json-vendor-config.txt"
  mkdir -p vendor/.cargo
  sed -n '/^\[source/,$p' "$WORK/json-vendor-config.txt" > vendor/.cargo/config.toml
  tar czf "$OUTDIR/redisjson-vendor-$JSON_VER.tar.gz" vendor )

# ---------------------------------------------------------------------------
# Source2 -- RediSearch vendored crates.
# Layout differs from RedisJSON: crates go in mycargo/ with the cargo config
# at the top level, plus a licence manifest shipped as %license.
# ---------------------------------------------------------------------------
echo "==> cargo vendor: redisearch"
SDIR="$WORK/redisearch-$SEARCH_VER"
rm -rf "$SDIR" && cp -a "$CLONE/modules/redisearch/src" "$SDIR"
( cd "$SDIR"
  rm -rf mycargo .cargo
  cargo vendor --manifest-path src/redisearch_rs/Cargo.toml mycargo \
      > "$WORK/rs-vendor-config.txt"

  # The `nix` crate ships a GPL-2.0 kernel-module test fixture that is never
  # compiled into redisearch.so. Drop it so licence scanners stay quiet, and
  # fix the checksum manifest so the offline cargo build still verifies.
  NIX=mycargo/nix
  if [ -f "$NIX/test/test_kmod/hello_mod/hello.c" ] && [ -f "$NIX/.cargo-checksum.json" ]; then
      rm -f "$NIX/test/test_kmod/hello_mod/hello.c"
      python3 - "$NIX/.cargo-checksum.json" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["files"].pop("test/test_kmod/hello_mod/hello.c", None)
p.write_text(json.dumps(d))
PYEOF
  fi

  mkdir -p .cargo
  sed -n '/^\[source/,$p' "$WORK/rs-vendor-config.txt" > .cargo/config.toml
  ( cd src/redisearch_rs && cargo tree --workspace --offline --edges=normal \
        --no-dedupe --prefix=none --format '{p} | {l}' 2>/dev/null \
      | grep -v '(/' | grep -v '| $' | sort -u > ../../rust-vendor-licenses.txt ) \
      || echo "# vendor licence manifest unavailable" > rust-vendor-licenses.txt
  tar czf "$OUTDIR/redisearch-vendor-$SEARCH_VER.tar.gz" \
      mycargo .cargo/config.toml rust-vendor-licenses.txt )

echo
echo "==> generated:"
ls -lh "$OUTDIR/redis-$TAG-full.tar.gz" \
       "$OUTDIR/redisjson-vendor-$JSON_VER.tar.gz" \
       "$OUTDIR/redisearch-vendor-$SEARCH_VER.tar.gz" | awk '{print "    " $5 "  " $9}'
