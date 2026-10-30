# HDA.R4D

`HDA.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.3.48`
- Image target: `/R4OS/DRIVERS/HDA.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

HDA enumerates bounded PCI class-04/03 candidates and initializes each viable
controller from codec evidence. Analog and digital controllers expose
independent output catalogs. Each candidate follows an explicit quiesce/reset/
STATESTS lifecycle. CORB/RIRB is the regular verb transport with negotiated
ring sizes, codec-matched responses and monotone timeouts. Immediate Commands
are used only when `OPTION HDA immediate=on` explicitly enables the visible
fallback; `OPTION HDA corb=off` can be combined with it for diagnostics.
Discovery covers all 15 codec addresses, every advertised audio function
group and the complete valid eight-bit node space without silent truncation.
The bounded controller snapshots include PCI identity and probe evidence.
Routine successful Stop/Idle/Close does not format large diagnostic blocks.
Set `OPTION HDA details=on` before loading the driver to request them; the
default is off. Init admission data and actual warnings/errors remain visible.

Requested completion details copy at most 2048 bytes under the stream owner,
then format after releasing it. Every snapshot binds the authenticated loaded
driver epoch, diagnostic sequence, output/reset identity, PCI function and
capture tick. A lazily allocated existing driver semaphore serializes these
explicit snapshots and is destroyed during successful shutdown. The normal
off path allocates no diagnostic resource and performs no detail capture.

LogService's 160-byte records carry bounded `HDA.SNAP`/`HDA.DET` fragments.
AUDIOD checks declared body lengths, all parts and the terminal counts before
accepting core/runtime/controller evidence. `/DETAILS` and `/OUT=<path>`
require a fresh complete snapshot; they fail if the boot option is off or
evidence is incomplete. `/OUT` writes that validated immutable snapshot.
Test-profile and hardware-acceptance images explicitly enable the option;
Slim and Full keep the default off.

NVIDIA PCIe controllers disable and verify No Snoop in their own Device Control
register before starting DMA into normal cached RAM. Legacy PCI controllers
use the vendor stream/transport snoop bits; modern GPUs need not implement
those old registers. Setup follows controller reset. Teardown restores
the original owned configuration bits only after all DMA stops; a failed
restoration retains the controller identity for cleanup. Other PCI bits and
non-NVIDIA controllers remain unchanged.

Short- and long-form connection lists, including range entries, are expanded
into a bounded per-codec graph. Controller evidence is viable only when this
graph proves a complete pin-to-converter route whose widgets and PCM
capabilities support 48-kHz stereo S16. Pin defaults rank speaker, headphone,
and line-out routes deterministically by association and sequence. HDMI/DP
routes additionally require current receiver and ELD evidence; digital pins
never enter the analog ranking.

The resulting verb plan powers the function group and required widgets to D0,
clears and verifies the converter stream, programs and verifies format
`0x0011`, configures every selected mixer/selector edge, derives unmuted 0-dB
amplifier values from the advertised capabilities, enables EAPD only when
supported, and finally assigns stream 1/channel 0. Presence-capable headphone
pins are checked through bounded status polling; without usable jack evidence
the selected speaker/line-out/headphone fallback remains fixed and visible in
the driver log.

Before each physical PCM or HDMI carrier start, HDA separately programs and
reads back the nonzero stream tag/direction while the descriptor is stopped.
Only then may it set `RUN`. A receiver appearing after initial DMA setup must
not keep the unassigned stream0 binding. Unconfirmed control refuses DMA
startup and leaves queued resources for the existing cleanup path. Ordinary
logical HDMI stream closes keep the established silent carrier; route changes
and driver shutdown retain their physical stop boundary.
The hardware stream is selected within the exact GCAP descriptor range. A
dedicated output descriptor is preferred; a bidirectional descriptor is used
only with its output-direction bit and only after route and 48-kHz stereo S16
capabilities agree. A 128-byte-aligned DMA position buffer is validated
against LPIB with deterministic fallback. Movement, wrap, frozen positions
and impossible jumps are tracked independently of status-poll frequency.
The compact close record reports the source actually used after these checks:
configured DMA, transient LPIB use, persistent LPIB fallback, and LPIB-only
operation remain distinct, with mismatch and fallback counters alongside the
normal runtime counters.

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

A selected, available HDMI sink keeps its cleared DMA ring running between
tones with completion IRQs disabled. This prevents the receiver's acquisition
delay from swallowing short sounds. After a physical clock start, writes
return Busy for up to one second before accepting PCM. Warm writes resume
from the actual hardware position with two silent lead periods. There is no
periodic quiet refill work; DMA still transfers 192,000 bytes/s. Analog and
DisplayPort retain the stopped-ring idle path. The appended AudioBackend v4
Idle callback needs Kernel 0.1.259; install these artifacts atomically. Route
replacement, receiver loss and shutdown continue to require physical Stop.

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

The physical 0.71.10 Lenovo acceptance completed on 30 August 2026. Cold and
warm runs selected the analog `1022:15E3`/`10EC:0257` path and consistently
reported `lpib-fallback pmis=3 pfb=3` with advancing writes and every stream,
recovery, timeout and work-drop counter at zero. Internal-speaker playback,
BEEP.R4X, R4BASIC BEEP/PLAY, AudioDiag, live volume and mute were heard;
headphones were unavailable and remain explicitly untested. No device quirk
is required.

`Tests/Prepare-HardwareAcceptanceImage.ps1` prepares the interactive Lenovo
acceptance image without flashing a device, preserves its hash-bound artifacts,
adds the test-only audio/hardware diagnostics to a Full-profile image, and
restores the normal Full profile afterward. The physical procedure, result
and strict evidence boundary are documented in
`Docs/Drivers/HdaHardwareAcceptance07110.txt`.

When an HDA-enabled physical boot stops before Desktop, the same script's
`-IsolationNoHda` switch creates a separately named and manifested Full image
whose temporary boot policy disables HDA without removing its artifact. It is
only a cause-isolation image: a successful boot is not audio or hardware
acceptance and must be followed by an identity- and stage-bound HDA probe.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


## AMD HDMI audio (0.80.22)

The 1002:15DE display controller accepts only the verified 1002:AA01 codec
revision 3 or later. Its vendor protocol replaces the standard ELD-RAM/DIP
path: Presence/ELDV, manufacturer/product, name, PortID, PCM descriptor and
lip sync must match the current copied AMDGPU route. A second route snapshot
rejects replacement during the read. Codec NIDs, AZ endpoints and display
heads are separate identities; ambiguous pin matches remain unavailable.

The bounded programming plan confirms stereo channel allocation, independent
slot remapping, 48 kHz S16 PCM, HBR off and converter ramp through vendor GET
verbs. Standard HDMI/DP and analog codec paths retain their existing plans.
Receiver revision changes stop stale streams; the shared AUDSVC policy owns
selection, master gain, mute and reopening. The known Lenovo analog path
1022:15E3 / 10EC:0257 is unchanged. No AMD audible hardware acceptance has
been performed in this milestone; that belongs to 0.80.39.

## Playback cursor and source flow (0.87.53)

The128-byte PlaybackBackend descriptor extends the unchanged104-byte idle
prefix with atomic tracked writes, playback snapshots and bounded source-flow
configuration. Canonical frames are48kHz/stereo/S16. Acceptance, actual DMA
payload and LPIB-consumed payload have separate counters; silent carrier and
period padding do not count. Slot payload intervals map partial/current DMA
positions to PCM sequence numbers. Output/reset generations and the last
nonempty retired epoch preserve only the known prefix across resets; unknown
data is never replayed or credited as consumed.

Continuous source flow caps hardware queue targets from the declared high
watermark (SNES:1920frames/four periods); other sources retain their existing
queue policy. Cursor/flow callbacks use existing stream ownership, no codec
I/O and no extra thread. Ordinary codec control retains the0.87.52 separation
described below. Native receipts and limits are documented by the workspace
audio owner in `Docs/Audio/PlaybackProgress.txt`.

## Codec control and published output state (0.87.52)

An on-demand control owner serializes codec transport, ELD reads, jack sensing
and route programming. Its ordinary `r4d-work` callbacks inspect at most one
physical HDMI pin using the existing bounded read. The producer or output
query advances the remaining finite sweep; after the last pin, the next sweep
becomes due in 250 ms. This adds no periodic thread or audio-deadline work.

Raw sink evidence stays with control. A complete checked snapshot is published
under the stream owner; PCM, status and DMA refill perform no codec I/O.
Duplicate pin associations remain unavailable without destroying raw evidence.
Receiver, ELD, port, source, revision, head or device-entry changes revoke the
selected route. Actual route transitions stop DMA and reserve the route before
dropping the stream lock for codec programming. Explicit selection revalidates
the physical receiver; PCM cannot use a route being programmed.

A contended refiller parks after one pass. Real stream release or IRQ-generation
progress can admit a successor. The waiter/pending handoff closes the race where
unlock occurs before the current pending claim is released. Stop and shutdown
join and release the actual ordinary and deadline handles; queued cancellation
also clears claims whose callbacks never ran. Codec I/O and shared error counters
have their own serialization or atomic access. Existing refill deadlines,
budgets, PCM geometry, drain, receiver validation and hardware ownership remain.

The owner test step passes 66 cases. Current-artifact KVM4 AudioDiag, four
restart/Close generations, real IRQ work and normal shutdown pass with zero
audio errors, deadline misses, overruns and rejected jobs. The original WAV
analyzer confirms the 7,607-frame signal span at 44,100 Hz. Hardware and final
STANDARD evidence is recorded in the project documentation `Audio/README.txt`.

Native qualification exposed an empty legacy controller-candidate array after
independent-controller registration. Each backend now retains its actual PCI
probe evidence (including distinct usable converters) and repeats that evidence
on ordinary Close and selected HDMI quiet idle. AudioDiag's mandatory candidate,
selection, core and runtime export checks remain intact; no criterion was relaxed.

Final OssiPC qualification runs with all 16 CPUs schedulable and the exact installed
0.3.42 file: real 10DE:228E/10DE009F HDMI, MSI/DMA+LPIB, strict AudioDiag
exports and zero error deltas. A real five-second cable removal changed the
receiver generation from 9 to 22, revoked the old route once and allowed fresh
error-free playback. The user confirmed the audible tone and visible desktop.
The one final KVM4 STANDARD and complete normalized R4OS Server readback are
valid; this broad unisolated run does not measure an isolated HDA speedup.
# Coherent output catalog (0.88.55)

DriverApi39 binds `AudioOutputEpochFn` to the existing playback backend. Its
try-only stream owner copies the published count, active index and a nonreused
catalog epoch. HDMI publication and route transitions advance that epoch,
including failed restoration. Initialization is published atomically; a
transition or exhausted epoch returns Busy. Scalar output queries and actual
route/Stop/ELD/playback acknowledgements retain their separate contracts.

R4OS0.88.59 removes only the unused write/refill duration bookkeeping.
The fixed128-byte AudioBackendStatus duration slots now return the explicit
Contract0.64.61 audio_duration_ticks_unavailable sentinel (UINT64_MAX).
Functional clocks/deadlines, PCM admission, DMA/IRQ progress, errors and
actual terminal Close remain in place. Never treat the sentinel as latency.
