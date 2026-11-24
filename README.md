# Nexagon-sm8750

Runtime Hexagon NPU (cDSP / HTP V79) unlock for the AYN Odin 3 Ultra (SM8750).

**Full guide:** [AYN_Odin3_Ultra_Hexagon_NPU_Guide.md](./AYN_Odin3_Ultra_Hexagon_NPU_Guide.md)

- `scripts/enable-cdsp.sh` — enables cDSP at runtime (boot script for `/data/adb/service.d/`)
- `scripts/spoof-sm8750.sh` — SoC spoofing helper
- `src/` — kCFI kernel module source (`enable_cdsp_clean.ko`)
- `prebuilt/` — prebuilt module binaries

Requires root (APatch / Magisk). Use at your own risk.
