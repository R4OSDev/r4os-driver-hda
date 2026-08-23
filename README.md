# HDA.R4D

`HDA.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.3.2`
- Image target: `/R4OS/DRIVERS/HDA.R4D`
- Image scope: `slim`
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

The driver uses sixteen fixed 10 ms DMA periods and a separate software PCM
queue. Caller packets are joined without normal-path zero padding; BDL, CBL
and LVI remain unchanged while RUN is set. MSI is preferred with INTx as the
fallback, and the ISR delegates refill and recovery to bounded Driver Work.
Stream-Close joins and releases every outstanding Driver-Work completion so
the shared queue returns to zero retained HDA slots while idle.

Detailed German technical notes are in `DOCUMENTATION.de.txt`. The normative
project-wide stream contract and reference comparison live in
`Docs/Drivers/HdaStreamContract.txt` and
`Docs/Drivers/HdaReferenceComparison.txt`. Source-transfer provenance is
recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
