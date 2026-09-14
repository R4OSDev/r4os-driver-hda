# Third-Party Notices

No third-party source code, binary, font, certificate, or other redistributable
material has been identified in this repository.

R4OS dependencies referenced by the build metadata are separate R4OS projects
and retain their own licenses and notices.

DisplayPort packet support (0.79.23): transport bytes and the NVIDIA HDA
checksum-layout convention were checked against Linux 7.2.4 hdmi.c/nvhdmi.c.
These GPL-2.0-or-later files are reference-only, archived with their original
notices and full GPL under GFX/0.79.23/displayport-20260914. No Linux source or
implementation is copied or linked into HDA.R4D; the packet encoder is original
R4OS code implementing protocol values.