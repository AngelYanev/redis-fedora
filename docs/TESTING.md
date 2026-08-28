# Testing

## Why there is a smoke test at all

"The RPM built" and "the module actually loads" are different claims. A
package can build cleanly, install cleanly, and still ship a `.so` that Redis
refuses to load — a missing companion library or a bad RPATH does exactly
that, and neither `rpmbuild` nor `rpmlint` will notice.

The smoke test therefore starts a real server and issues real commands.

## Running it

```bash
make smoke                      # install from Copr, test everything
make smoke-local                # same, against `make mock` output
```

Directly, with more control:

```bash
scripts/smoke-test.sh copr fedora-43-x86_64
scripts/smoke-test.sh local ~/mock-results/redis-8.10.1-4
```

It installs into a throwaway root under `~/.cache/redis-smoke`, starts
`redis-server` in a chroot, asserts, then tears down. Exit status is non-zero
if any assertion fails.

> It installs under `$HOME`, not `/tmp`, on purpose: `/tmp` is often a small
> tmpfs and a full install root does not fit. That failure looks like a
> dependency error, which is misleading.

## What it asserts

### 1. `dnf install redis` — plain server

| Check | Expected |
|---|---|
| `PING` | `PONG` |
| `VADD` (vector sets) | works — compiled into the binary |
| `JSON.SET` | **`unknown command`** |
| `BF.ADD` | **`unknown command`** |
| `TS.ADD` | **`unknown command`** |
| `FT.CREATE` | **`unknown command`** |

The four "unknown command" results are the point, not a failure. They are
what proves a plain install really is plain — that no module leaked in via a
weak dependency and no stale `loadmodule` stub is lying around.

This matters because it has been wrong before: while old per-module packages
were still published, they carried `Supplements: redis`, so `dnf install redis`
silently dragged in four unwanted module packages. Only a runtime check
catches that.

### 2. `dnf install redis-full` — server with every module

| Module | Commands exercised |
|---|---|
| vector sets | `VADD` |
| RedisJSON | `JSON.SET`, `JSON.GET` |
| RedisBloom | `BF.ADD`, `BF.EXISTS` (hit **and** miss) |
| RedisTimeSeries | `TS.CREATE` with retention, `TS.ADD` |
| RediSearch | `FT.CREATE`, then `HSET` and `FT.SEARCH` for a real match |

RedisBloom is checked for both a hit and a miss — `BF.EXISTS` returning `1`
for everything would pass a naive test while being completely broken.

RediSearch indexes a document and searches for it, rather than just creating
an index, because index creation succeeds even when the module cannot actually
index.

## What it does not cover

Be clear about the gaps:

- **No persistence testing.** RDB/AOF round-trips, and module data surviving a
  restart, are not exercised.
- **No cluster or sentinel testing.** Sentinel ships but is untested here.
- **No upgrade testing.** Going from an older installed version to this one,
  and what happens to `%config(noreplace)` files, is not covered.
- **Single chroot per run.** `make smoke` tests one chroot; Copr builds eight.
  Pass a chroot name to test others.
- **Not a functional test suite.** Upstream's own test suites are not run.
  `%check` in the spec only asserts that the expected artefacts exist.

## Manual verification

```bash
sudo dnf copr enable @redis/redis
sudo dnf install redis-full
sudo systemctl enable --now redis
redis-cli MODULE LIST
```

Expect five entries: `search`, `ReJSON`, `bf`, `timeseries`, `vectorset`.
Module versions are reported in Redis's packed form — `81000` is 8.10.0,
`81001` is 8.10.1.

## Linting

```bash
make lint
```

Runs `rpmlint` against the spec and any built RPMs, using
`sources/redis.rpmlintrc`. That file filters exactly two things, both
justified in comments: the missing-URL warning for the three generated
tarballs, and `no-documentation` where it does not apply.
