# Maintenance: bumping to a new Redis release

A version bump is **not** just editing `Version:`. Three of the Sources are
generated and must be regenerated, and one upstream pin has to be re-checked
by hand.

## Procedure

### 1. Find out what upstream pins

Every module version is decided by `modules/modules.yaml` in the Redis tree,
not by you:

```bash
curl -s https://raw.githubusercontent.com/redis/redis/<newtag>/modules/modules.yaml
```

Read the `ref:` for each module. They do **not** all match the core tag — for
8.10.1, RedisBloom was `v8.10.1` while the other three were `v8.10.0`.

### 2. Re-check RediSearch's FetchContent pins

**This is the step that will bite you.** RediSearch pins its CMake
dependencies inside its own tree, and they move between releases:

```bash
git clone https://github.com/RediSearch/RediSearch && cd RediSearch
git checkout v<search_ver>
grep -rn "GIT_TAG" deps/VectorSimilarity/deps/ScalableVectorSearch/cmake/ \
                   deps/VectorSimilarity/cmake/
```

Compare against the `%global` values in `redis.spec`:

```
cpu_features_ver, eve_ver, robinmap_ver, fmt_ver, spdlog_ver, toml_ver
```

RediSearch 8.10.0 moved **fmt from 11.2.0 to 12.1.0**. A stale pin does not
fail fast — it fails at CMake configure time, after you have already waited
through most of the build.

### 3. Edit the spec

```
Version:        <newtag>
Release:        1%{?dist}

%global bloom_ver      <from modules.yaml>
%global search_ver     <from modules.yaml>
%global json_ver       <from modules.yaml>
%global timeseries_ver <from modules.yaml>

%global fmt_ver ...    <from step 2, if changed>
```

Add a `%changelog` entry. Do not write bare `%{version}` in changelog text —
rpmlint flags `macro-in-%changelog`; escape as `%%{version}`.

If `redis-full`'s `Obsoletes:` bounds are still `< 8.10.1-4`, leave them; they
only matter for upgrades from the short-lived per-module packages.

### 4. Regenerate sources and build

```bash
make sources     # needs network: make tarball + both cargo vendors
make download    # FetchContent deps
make srpm
make copr        # or `make mock` for a local check first
```

### 5. Verify

```bash
make smoke                          # default chroot
make smoke MOCK_CFG=fedora-43-x86_64
```

Do not skip this. A green build does not mean the modules load.

## Things that will go wrong

### The module ABI changed

```
Error: Upstream API version is now 2, expecting 1.
```

`%prep` compares `REDISMODULE_APIVER_*` against `%global redis_modules_abi`.
This is a deliberate guard. Investigate whether modules built against the old
ABI still load before simply bumping the macro.

### A new FetchContent dependency appeared

CMake will fail with something like `Could not find <name>`. Add it as a new
`SourceN`, a `%global <name>_ver`, and a matching
`-DFETCHCONTENT_SOURCE_DIR_<NAME>=` line in `%build`. Remember there are
currently **seven** such dependencies — Boost comes from the system, not a
Source.

### The build fails only on rawhide or F45

Almost always a retired or renamed BuildRequires. This happened with
`rust-lazycell-devel`, retired in F45+: F43 and F44 passed while F45 and
rawhide failed on **both** architectures.

Check availability before building:

```bash
dnf --releasever=rawhide repoquery --whatprovides <package>
```

Local mock alone will not catch this — it only tests one chroot. Copr's matrix
is what surfaces it.

### `make sources` is slow

It clones Redis, then every module with submodules, then vendors two Rust
workspaces. The clone is cached in `~/.cache/redis-sources` and reused. Use
`make distclean` to reset it.

## Release checklist

- [ ] `modules.yaml` refs read from the new tag, `%global *_ver` updated
- [ ] RediSearch FetchContent pins re-checked (especially `fmt`)
- [ ] `Version:` bumped, `Release:` reset to 1
- [ ] `%changelog` entry added, macros escaped
- [ ] `make sources && make srpm`
- [ ] `make lint` clean
- [ ] `make copr` green on **all** chroots, not just one
- [ ] `make smoke` passes
- [ ] Spot-check `redis-cli MODULE LIST` shows five entries with the expected versions
