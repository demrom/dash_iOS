# Dash xcframeworks

Run `bash build_dash.sh` on macOS with Xcode 26.6 selected, then audit the six ZIPs with `uv run ci/audit-artifact.py ZIP --sha256 SHA256 --max-minos 14.0`. The recipe records its tools, uses two compile jobs at nice 15, and rebuilds owned outputs on reruns.

The recipe builds Dash source `ad90d1ac7231b38b558851ce9ef1e98424536772`, ios_system `b51dd90d778499b3592258988423008515282196`, and libedit `20260512-3.1` with this source's socket patch. The Dash commit must be present in Git history; CI checks out full history. Source archives, patch and published ABI baselines are checksum verified. Missing configure helper scripts come from the pinned GNU Automake 1.19 archive; no Autotools installation or regeneration is required. The core uses its existing Xcode target. Each product has an arm64 device slice and one universal arm64/x86_64 Simulator slice, minimum iOS 14. libedit is static; no host libedit is linked. The pinned libedit header precedes Dash's older bundled header.

Outputs are `.build/dash/products/{dash,dashA,dashB,dashC,dashD,dashE}.xcframework.zip`, checksums, export/closure reports and `release.md`. The source-built core ZIP and toolchain receipt under `.build/dash/audit` accompany CI artifacts for independent closure checks. They are audit inputs, not additional release products. `SOCKET-INPUT.md` defines the app callbacks and input contract; compilation and ABI checks alone do not qualify app execution.

CI runs for pull requests, manual dispatch and `dash-v*` tags. Only matching tags in `holzschu/dash_iOS` publish the six audited ZIPs and checksums. Releases preserve existing assets and do not change the latest release. To publish, create the version tag after merging; use the published ZIP's checksum when updating a consumer.
