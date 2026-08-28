# Design: why one SRPM with subpackages

## The problem

Redis and its modules were packaged as **five separate SRPMs**, in five git
repos owned by three different people:

```
redis-rpm            -> redis, redis-devel
redisbloom-rpm       -> redisbloom
redisearch-rpm       -> redisearch
redisjson-rpm        -> redisjson
redistimeseries-rpm  -> redistimeseries
```

Each built independently. That independence caused real, observed breakage:

| Problem found | Consequence |
|---|---|
| `redisearch` and `redisjson` used `Version: 1.0.0` while the rest tracked upstream | two incompatible versioning conventions in one repo |
| `redistimeseries` had `Requires: redis = %{version}` | **unsatisfiable** — module 8.10.0 vs core 8.10.1 |
| `redisbloom` and `redisjson` had no runtime dependency on redis at all | a module `.so` installable with no server to load it |
| `redisjson` and `redisearch` both declared `%dir /etc/redis/modules`, which `redis` already owned with different permissions | **blocked co-installation** — the dnf transaction failed outright |
| `redisjson`'s `Source0` pointed at a GitHub repo that does not exist | unbuildable from the spec alone |

None of these are possible with a single spec.

## Why the split was never buying anything

Upstream pins each module to an exact ref in `modules/modules.yaml`, **per core
release**. Redis 8.10.1 ships redisbloom `v8.10.1` and the other three at
`v8.10.0`; that exact combination is what upstream tests. You cannot ship
redisjson 8.11 against redis 8.10 anyway, so an independent release cadence
per module has nothing to offer.

## What was rejected, and why

Three shapes were considered.

### A. Keep five SRPMs, add a `redis-full` metapackage

A 6.7 KB package containing no files, listing the five as dependencies.
Works, and it shipped — but it only papers over the split. Every problem in
the table above remains, and there are still five things to bump.

### B. One monolithic package containing everything

A single `redis-full` RPM with the server and all modules inside, carrying
`Conflicts:` against the five split packages.

Rejected. It shipped the same paths as the existing packages, so it could
never be co-installed with them, and users could not mix. It also failed four
build attempts on packaging mechanics (see BUILDING.md) before being
abandoned. A monolith gives up granularity without buying consistency that
option C does not already provide.

### C. One SRPM, several subpackages  ← chosen

One source, one build, several ordinary RPMs. Single source of truth from
`modules.yaml`, no `Conflicts:` hackery, packages stay co-installable and
individually removable.

## The final grouping

Subpackages were initially one per module (`redisbloom`, `redisearch`,
`redisjson`, `redistimeseries`). That was collapsed: the modules now ship as
a single `redis-full` package, because the requirement is to install either a
plain server or a server with everything — not to hand-pick modules.

```
redis.spec
  |-- redis          server, cli, sentinel, vector sets
  |-- redis-devel    redismodule.h + RPM macros
  `-- redis-full     all four modules + their loadmodule stubs
```

`redis-full` carries `Obsoletes:` for the short-lived per-module packages
(8.10.1-3), so upgrading replaces them instead of leaving orphans whose
`loadmodule` stubs point at deleted `.so` files.

## How modules activate

`redis-conf.patch` adds one line to `redis.conf`:

```
include /etc/redis/modules/*.conf
```

`redis-full` drops a stub per module into that directory:

```
/etc/redis/modules/redisbloom.conf   -> loadmodule /usr/lib64/redis/modules/redisbloom.so
/etc/redis/modules/search.conf       -> loadmodule /usr/lib64/redis/modules/redisearch.so
/etc/redis/modules/redisjson.conf    -> loadmodule /usr/lib64/redis/modules/rejson.so
/etc/redis/modules/timeseries.conf   -> loadmodule /usr/lib64/redis/modules/redistimeseries.so
```

So installing the package is what enables the modules — no config editing.
A plain `redis` install leaves that directory empty and the glob matches
nothing, which Redis handles fine (verified).

## Vector sets are not a module

Upstream compiles them into the server binary — `src/Makefile` builds
`hnsw.o`, `vset.o` and `vset_config.o` under `-DINCLUDE_VEC_SETS=1`. They
appear in `MODULE LIST` as `vectorset` with no package providing them, and
`VADD`/`VSIM` work on a plain `redis` install. Nothing to package.

## The cost of this design

Being honest about the trade-off:

- **No independent module rebuilds.** A RedisJSON-only fix means rebuilding
  everything, including RediSearch's ~40 minutes.
- **Failure coupling.** If one module fails to compile, *nothing* ships. This
  is not theoretical: during development, core and RedisBloom built fine while
  RedisJSON and RedisTimeSeries failed, and the whole build produced zero
  packages.
- **Version inflation.** `redis-full` carries the core version (8.10.1) even
  though RediSearch upstream is 8.10.0. Actual upstream refs are recorded in
  the `%global *_ver` macros and stated in the package description.

If independent module hotfixes ever become necessary, the old per-module specs
remain in git history and a single-module spec can be revived.
