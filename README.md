# HDA.R4D

`HDA.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.3.11`
- Image target: `/R4OS/DRIVERS/HDA.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

HDA 0.3.11 enumerates every bounded PCI class-04/03 candidate and selects a
complete analog-capable controller from codec evidence instead of accepting
the first function. Each candidate follows an explicit quiesce/reset/
STATESTS lifecycle. CORB/RIRB is the regular verb transport with negotiated
ring sizes, codec-matched responses and monotone timeouts. Immediate Commands
are used only when `OPTION HDA immediate=on` explicitly enables the visible
fallback; `OPTION HDA corb=off` can be combined with it for diagnostics.
Discovery covers all 15 codec addresses, every advertised audio function
group and the complete valid eight-bit node space without silent truncation.

Short- and long-form connection lists, including range entries, are expanded
into a bounded per-codec graph. Controller evidence is viable only when this
graph proves a complete analog pin-to-converter route whose widgets and PCM
capabilities support 48-kHz stereo S16. Pin defaults rank speaker, headphone,
and line-out routes deterministically by association and sequence; digital
pins never enter that selection.

The resulting verb plan powers the function group and required widgets to D0,
clears and verifies the converter stream, programs and verifies format
`0x0011`, configures every selected mixer/selector edge, derives unmuted 0-dB
amplifier values from the advertised capabilities, enables EAPD only when
supported, and finally assigns stream 1/channel 0. Presence-capable headphone
pins are checked through bounded status polling; without usable jack evidence
the selected speaker/line-out/headphone fallback remains fixed and visible in
the driver log.

The hardware stream is selected within the exact GCAP descriptor range. A
dedicated output descriptor is preferred; a bidirectional descriptor is used
only with its output-direction bit and only after route and 48-kHz stereo S16
capabilities agree. A 128-byte-aligned DMA position buffer is validated
against LPIB with deterministic fallback. Movement, wrap, frozen positions
and impossible jumps are tracked independently of status-poll frequency.

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
normal-path zero padding; BDL, CBL and LVI remain unchanged while RUN is set.
MSI is preferred; INTx is accepted only from the exact PCI line/pin evidence
and never guessed from neighboring GSIs. The ISR acknowledges BCIS/FIFOE/DESE
once and delegates refill and controlled error recovery to bounded Driver Work.
Each pass declares a 10 ms deadline, a stable HDA key, and a bounded callback
budget on the isolated DriverApi-v20 audio lane. A callback performs one pass
and submits at most one freshly deadline-stamped successor. Stream-Close
drains short tails and joins every outstanding Driver-Work completion after
releasing the stream lock, so the shared queue returns to zero retained HDA
slots while idle. Completion inspection and release are serialized outside
IRQ context, and shutdown joins all retained work before position, ring or BDL
DMA is disabled and freed.

An explicit ownership ledger covers PCI, MMIO, reset, transport, discovery,
route, stream/position DMA, IRQ, backend and Driver Work. Partial
initialization is unwound through the concrete handles and can be repeated
without a second free. A failed graceful drain performs a forced stop that
clears queued and DMA PCM before reporting the error; an IRQ, MSI, work or
transport resource that cannot be proven quiescent remains owned for a later
cleanup attempt. The supported owner unload/reload generation is modeled as a
complete teardown followed by fresh reacquisition with no retained PCM. Two
bounded `HDA.DIAG` records expose controller/route/format
and runtime/recovery/timeout state without per-write or per-IRQ logging.

Detailed German technical notes are in `DOCUMENTATION.de.txt`. The normative
project-wide stream contract and reference comparison live in
`Docs/Drivers/HdaStreamContract.txt` and
`Docs/Drivers/HdaReferenceComparison.txt`. Source-transfer provenance is
recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
