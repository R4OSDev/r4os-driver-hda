# HDA.R4D

`HDA.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.3.7`
- Image target: `/R4OS/DRIVERS/HDA.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

The driver uses a 64-period DMA ring, starts after two ready 10 ms periods,
and has a separate software PCM queue. Caller packets are joined without
normal-path zero padding; BDL, CBL
and LVI remain unchanged while RUN is set. MSI is preferred with INTx as the
fallback, and the ISR delegates refill and recovery to bounded Driver Work.
Each pass declares a 10 ms deadline, a stable HDA key, and a bounded callback
budget on the isolated DriverApi-v20 audio lane. A callback performs one pass
and submits at most one freshly deadline-stamped successor. Stream-Close
drains short tails and joins every outstanding Driver-Work completion after
releasing the stream lock, so the shared queue returns to zero retained HDA
slots while idle.

Detailed German technical notes are in `DOCUMENTATION.de.txt`. The normative
project-wide stream contract and reference comparison live in
`Docs/Drivers/HdaStreamContract.txt` and
`Docs/Drivers/HdaReferenceComparison.txt`. Source-transfer provenance is
recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
