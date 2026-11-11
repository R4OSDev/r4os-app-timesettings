# TIMESET.R4X

`TIMESET.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.9`
- Image target: `/R4OS/SOFTWARE/DESKTOP/TIMESET.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

API migration 0.90.67
---------------------
App2 uses the normal SDK201/Contract93/Libraries57 and Query2 platform binding.
DATE_V1/TIME_V1 keep their independent library contract. TIMESVC operations
use the shared ServiceConnection with one checked absolute one-second budget.
Only an exact validated response and acknowledged connection close publish
the result. An unconfirmed save keeps the window open and requests reload.
The caller sends each mutation once. Font changes rebuild Canvas and layout.
