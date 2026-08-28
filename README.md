# Redis RPM packaging for Fedora

Builds Redis **and every module upstream bundles with it** from a single
source, and ships two things you can install:

| Package | What you get |
|---|---|
| `redis` | Plain server: `redis-server`, `redis-cli`, `redis-sentinel`. Vector sets included (compiled into the binary). No modules. |
| `redis-full` | The same server plus **RediSearch, RedisJSON, RedisBloom and RedisTimeSeries**, active on restart. |

```bash
sudo dnf copr enable @redis/redis
sudo dnf install redis          # plain
# or
sudo dnf install redis-full     # everything
sudo systemctl enable --now redis
```

There is no partial state: either no modules, or all of them.

`redis-devel` is also built, for compiling third-party modules against this Redis.

## Why one spec

Redis 8.x pins each bundled module to an exact upstream ref in
`modules/modules.yaml` and builds them through its own `modules/common.mk` +
`scripts/build.sh`. Packaging that as **one** SRPM means module versions can
never drift from the core they were tested against, and there is a single
place to bump.

This replaces five previously separate packaging repos. See
[docs/DESIGN.md](docs/DESIGN.md) for how that decision was reached and what it
costs.

## Quick start

```bash
make help          # list every target
make check-tools   # verify your toolchain
make sources       # regenerate the generated tarballs (needs network)
make srpm          # build the source RPM
make mock          # build locally in a clean chroot (~1h on 2 cores)
make smoke         # install from Copr and test every module
```

Full pipeline: `make all` (sources → srpm → mock → lint).

## Layout

```
redis.spec              the only file you edit for a version bump
Makefile                reproducible build + test entry points
sources/                static sources: systemd units, sysusers, tmpfiles,
                        logrotate, the redis.conf patch, rpmlintrc
scripts/
  make-sources.sh       regenerates the three generated tarballs
  smoke-test.sh         installs into a throwaway root and asserts behaviour
docs/
  DESIGN.md             why one SRPM with subpackages; what was rejected
  BUILDING.md           how the build works, and every offline-build trap
  TESTING.md            what the smoke tests prove, and how to run them
  MAINTENANCE.md        step-by-step version bump procedure
```

## Documentation

- **[docs/DESIGN.md](docs/DESIGN.md)** — the packaging model and the reasoning
- **[docs/BUILDING.md](docs/BUILDING.md)** — build mechanics and offline gotchas
- **[docs/TESTING.md](docs/TESTING.md)** — how the packages are verified
- **[docs/MAINTENANCE.md](docs/MAINTENANCE.md)** — bumping to a new Redis release
- **[AGENTS.md](AGENTS.md)** — guidance for coding agents working on this repo
  (also the place the non-obvious failure modes are written down)
- **[MAINTAINERS.md](MAINTAINERS.md)** — provenance, ownership, open decisions
