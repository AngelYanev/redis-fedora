# CLAUDE.md

The guidance for this repo lives in **[AGENTS.md](AGENTS.md)** — read it before
making changes. It covers the packaging model, the offline-build constraints,
and eleven specific traps that produce plausible-looking but broken changes.

Points worth repeating because they are easy to get wrong in a single session:

- **Building is not verifying.** A package can build, install and lint cleanly
  while shipping a module Redis cannot load. Run `make smoke`; if you have not,
  say so rather than implying the packages were verified.
- **`@redis/redis` on Copr is a shared team repo.** Publishing there is
  outward-facing. Do not submit unverified builds, and never delete package
  entries without explicit confirmation — it is irreversible.
- **A version bump is not just `Version:`.** Three Sources are generated and
  need `make sources`. See [docs/MAINTENANCE.md](docs/MAINTENANCE.md).
- **Check per-chroot Copr results**, not just the overall status. A real
  failure passed F43 and F44 while failing F45 and rawhide.
- **Diagnose, do not guess.** At least one build error here
  (`Cannot find python3 interpreter`) names the wrong cause entirely.

Repo documentation:

| File | Contents |
|---|---|
| [AGENTS.md](AGENTS.md) | agent guidance, ground rules, the traps |
| [README.md](README.md) | what this is, quick start, layout |
| [docs/DESIGN.md](docs/DESIGN.md) | why one SRPM; what was rejected and why |
| [docs/BUILDING.md](docs/BUILDING.md) | build mechanics, offline gotchas |
| [docs/TESTING.md](docs/TESTING.md) | what tests prove — and what they do not |
| [docs/MAINTENANCE.md](docs/MAINTENANCE.md) | version bump procedure |
