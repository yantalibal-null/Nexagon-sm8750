# Enabling Qualcomm Hexagon NPU (CDSP / HTP V79) on AYN Odin 3 Ultra (SM8750 / Snapdragon 8 Elite)

> **Myth Debunked:** The Hexagon NPU (CDSP) on the **AYN Odin 3 Ultra** (24 GB LPDDR5X, SM8750 / CQ8725S) is **NOT fused off (eFuse) at the factory**. The silicon is 100% functional and authenticated by TrustZone (PAS). It is merely disabled at cold boot via a software binning mask (`PartialGoods: 0x9040`) in XBL/UEFI.

This guide covers full NPU enablement and zero-copy DMA-BUF shared memory setup for both **Android 15 (GKI 6.6.87)** and **Linux / SteamOS ARM64 (Zaviya / ROCKNIX OpenABL)**.

---

## 1. Root Cause Analysis: Why the NPU Appears Dead Out of the Box

1. **UEFI / XBL Software Binning (`PartialGoods: 0x9040`):**
   During cold boot on Android, Qualcomm's `ChipInfo` / `LinuxLoader` applies `PartialGoods for Multimedia: 0x9040`, dynamically patching `/soc/remoteproc-cdsp@32300000` in the in-memory Device Tree Blob (DTB) to `status = "no"` / `"disabled"`.
2. **Why `dtbo` / `vendor_boot` Patching Fails:**
   Even if you modify `dtbo_a` or `vendor_boot_a`, UEFI overwrites the DTB property back to `"disabled"` on every boot. Furthermore, modifying `vbmeta_a` without proper AVB re-signing triggers `HASH_MISMATCH` and boots into Recovery.
3. **Why Linux Works Natively:**
   Open-source bootloaders (OpenABL / ROCKNIX) used to boot SteamOS ARM64 / Zaviya do not execute Qualcomm's `PartialGoods: 0x9040` filter, leaving `32300000.remoteproc` enabled out of the box.

---

## 2. Verified Hardware Proof & Benchmark (Android 15)

Once the CDSP node is re-enabled at runtime, TrustZone loads `/vendor/firmware_mnt/image/cdsp.mdt` + `cdsp.b00..b15`, initializes all 12 IOMMU compute contexts (`compute-cb@1..12`), and exposes `/dev/fastrpc-cdsp` and `/dev/fastrpc-cdsp-secure`.

* **Kernel Node:** `remoteproc3` -> `32300000.remoteproc-cdsp` (`state: running`)
* **Test App:** PocketPal AI (`v1.24.0`, Hexagon backend)
* **Model:** `Meta-Llama-3.1-8B-Instruct-Q4_0.gguf`
* **Measured Performance:** **`10.83 tok/s`** generation, **`179–189 ms` TTFT**
* **Kernel File Descriptors (`/proc/<pid>/fd`):**
  ```text
  145 -> /dev/dma_heap/system
  152 -> /dev/fastrpc-cdsp-secure
  174 -> /dev/fastrpc-cdsp-secure
  208 -> /dev/fastrpc-cdsp-secure
  220 -> /dev/fastrpc-cdsp-secure
  ```

---

## 3. Part A: Enabling Hexagon NPU on Android 15 (GKI 6.6.87, No Partition Flashing)

Instead of touching `boot`, `dtbo`, or `vbmeta`, we load a small out-of-tree kernel module (`enable_cdsp_clean.ko`) via **APatch** or **Magisk** after boot. It locates `/soc/remoteproc-cdsp@32300000`, switches `status` to `"okay"` via a writable `.data` pointer (avoiding FDT read-only page faults), and calls `of_platform_device_create()`.

### 3.1 Kernel Requirements (`6.6.87-android15-8-maybe-dirty-4k`)

The stock GKI 6.6.87 kernel enforces:
* `CONFIG_MODVERSIONS=y`
* `CONFIG_ARM64_MODULE_PLTS=y`
* `CONFIG_CFI_CLANG=y` (`kCFI`)

**Extracted Symbol CRCs (`__versions`):**

| Symbol | CRC32 |
| :--- | :--- |
| `module_layout` | `0x4e276f37` |
| `_printk` | `0x92997ed8` |
| `of_find_node_opts_by_path` | `0x7c497915` |
| `of_find_property` | `0x8a964733` |
| `of_platform_device_create` | `0x1cbd13c2` |

**kCFI Type Hashes (4 bytes preceding function entry):**
* `init_module` (`int (*)(void)`): `0x36b1c5a6`
* `cleanup_module` (`void (*)(void)`): `0xa540670c`

**`struct module` Offsets (`.gnu.linkonce.this_module`, size `0x600`):**
* `name`: `0x18`
* `init`: `0x188`
* `exit`: `0x5B8`

### 3.2 Building the Module On-Device in Termux

Install build tools in Termux (non-root):

```bash
pkg update && pkg install -y clang lld llvm
mkdir -p ~/ko_build && cd ~/ko_build
```

Create `mod.c`:

```c
struct property {
    char *name;
    int length;
    void *value;
    struct property *next;
};

struct device_node;
struct platform_device;

extern int _printk(const char *fmt, ...);
extern struct device_node *of_find_node_opts_by_path(const char *path, const char **opts);
extern struct property *of_find_property(const struct device_node *np, const char *name, int *lenp);
extern struct platform_device *of_platform_device_create(struct device_node *np, const char *bus_id, void *parent);

static char new_status[] = "okay";

int __attribute__((section(".init.text"), used)) real_init(void)
{
    struct device_node *np = of_find_node_opts_by_path("/soc/remoteproc-cdsp@32300000", 0);
    if (!np) {
        _printk("3enable_cdsp: node not found
");
        return -19;
    }

    int len = 0;
    struct property *prop = of_find_property(np, "status", &len);
    if (prop) {
        prop->value = new_status;
        prop->length = 5;
    }

    struct platform_device *pdev = of_platform_device_create(np, 0, 0);
    _printk("6enable_cdsp: of_platform_device_create -> %p
", pdev);
    return pdev ? 0 : -5;
}

void __attribute__((section(".exit.text"), used)) real_exit(void)
{
    _printk("6enable_cdsp: unloaded
");
}
```

Create `mod_meta.S` (note the non-empty `.plt`, `.init.plt`, and `.text.ftrace_trampoline` padding to prevent ARM64 PLT loader overflows):

```asm
.section .init.text, "ax", @progbits
.align 2
.word 0x36b1c5a6
.global init_module
.type init_module, %function
init_module:
    b real_init

.section .exit.text, "ax", @progbits
.align 2
.word 0xa540670c
.global cleanup_module
.type cleanup_module, %function
cleanup_module:
    b real_exit

.section .modinfo, "a", @progbits
.asciz "name=enable_cdsp_kcfi"
.asciz "vermagic=6.6.87-android15-8-maybe-dirty-4k SMP preempt mod_unload modversions aarch64"
.asciz "license=GPL"

.section __versions, "a", @progbits
.align 3
.quad 0x4e276f37
.asciz "module_layout"
.balign 64, 0

.quad 0x92997ed8
.asciz "_printk"
.balign 64, 0

.quad 0x7c497915
.asciz "of_find_node_opts_by_path"
.balign 64, 0

.quad 0x8a964733
.asciz "of_find_property"
.balign 64, 0

.quad 0x1cbd13c2
.asciz "of_platform_device_create"
.balign 64, 0

.section .gnu.linkonce.this_module, "aw", @progbits
.align 6
.global __this_module
.type __this_module, %object
__this_module:
    .space 0x18
    .asciz "enable_cdsp_kcfi"
    .org __this_module + 0x188
    .quad init_module
    .org __this_module + 0x5B8
    .quad cleanup_module
    .org __this_module + 0x600
.size __this_module, 0x600

.section .plt, "ax", @progbits
.space 1024

.section .init.plt, "ax", @progbits
.space 1024

.section .text.ftrace_trampoline, "ax", @progbits
.space 1024
```

Compile and strip LLVM metadata sections (prevents toybox `insmod` segfaults):

```bash
clang --target=aarch64-linux-gnu -ffreestanding -fno-builtin -fno-stack-protector -O2 -c mod.c -o mod.o
clang --target=aarch64-linux-gnu -c mod_meta.S -o mod_meta.o
ld.lld -r mod_meta.o mod.o -o enable_cdsp_kcfi.ko
llvm-objcopy --remove-section=.llvm_addrsig --remove-section=.comment --remove-section=.note.GNU-stack enable_cdsp_kcfi.ko enable_cdsp_clean.ko
```

### 3.3 Exposing QNN HTP V79 Skeleton & Boot Auto-Start (`/data/adb/service.d/enable-cdsp.sh`)

On stock Odin 3 firmware, `libQnnHtpV79Skel.so` (8.0 MB) resides in `/vendor/etc/ASR_binary/Whisper/` instead of `/vendor/dsp/cdsp/`, where `vendor.cdsprpcd` expects it. Additionally, `/dev/dma_heap/system` defaults to `0444` (`r--r--r--`), which blocks non-root DMA-BUF allocations.

Save the following boot script as `/data/adb/service.d/enable-cdsp.sh` (`chmod 0755`):

```sh
#!/system/bin/sh
echo 0 > /proc/sys/kernel/panic_on_oops
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 3

# 1. Bind-mount libQnnHtpV79Skel.so into /vendor/dsp/cdsp for vendor.cdsprpcd
if [ ! -f /vendor/dsp/cdsp/libQnnHtpV79Skel.so ]; then
    mkdir -p /data/local/tmp/dsp_overlay
    cp -a /vendor/dsp/cdsp/* /data/local/tmp/dsp_overlay/
    cp -f /vendor/etc/ASR_binary/Whisper/libQnnHtpV79Skel.so /data/local/tmp/dsp_overlay/
    chmod 0644 /data/local/tmp/dsp_overlay/*
    chcon -R u:object_r:vendor_file:s0 /data/local/tmp/dsp_overlay/
    mount --bind /data/local/tmp/dsp_overlay /vendor/dsp/cdsp
fi

# 2. Load kCFI kernel module via finit_module syscall (273)
/data/data/com.termux/files/usr/bin/python3 -c "import ctypes, os; libc = ctypes.CDLL(None, use_errno=True); fd = os.open("/data/local/tmp/npu/enable_cdsp_clean.ko", os.O_RDONLY); libc.syscall(273, fd, b"", 0); os.close(fd)"
sleep 2

# 3. Grant RW permissions to FastRPC & DMA-BUF heaps + SELinux live policy
chmod 0666 /dev/fastrpc-cdsp /dev/fastrpc-cdsp-secure /dev/dma_heap/system /dev/dma_heap/qcom,system /dev/dma_heap/qcom,cma-secure-cdsp 2>/dev/null
/data/adb/ap/bin/magiskpolicy --live   "allow untrusted_app vendor_xdsp_device chr_file { read write open ioctl getattr }"   "allow untrusted_app fastrpc_device chr_file { read write open ioctl getattr }"   "allow untrusted_app dmabuf_system_heap_device chr_file { read write open ioctl getattr }" 2>/dev/null

# 4. Restart CDSP user-space daemon
stop vendor.cdsprpcd
start vendor.cdsprpcd
```

> **Note for APatch Users:** If an app still cannot enumerate the NPU under strict SELinux isolation, grant it access in the APatch Manager app list or apply the `magiskpolicy --live` rules above. Always use pure **`Q4_0`** or **`Q8_0`** `.gguf` models for Hexagon HTP acceleration.

---

## 4. Part B: Hexagon NPU & 24 GB Unified Memory in Linux / SteamOS ARM64 (Zaviya)

1. **Hardware & Remoteproc:**
   * OpenABL / ROCKNIX bootloader leaves `remoteproc1` (`/sys/devices/platform/soc@0/32300000.remoteproc`, `name = cdsp`) running natively using `/lib/firmware/qcom/sm8750/ayn/odin3/cdsp.mbn`.
2. **Extracting DSP Binaries from Factory Dump:**
   * From `dsp_a` (`dspso.bin` -> `/cdsp/`): copy `fastrpc_shell_3`, `fastrpc_shell_unsigned_3`, `libc++.so.1`, `libc++abi.so.1`, `libsynx*.so`, `libUbwcD.so`, and all `*_skel.so` into `/usr/lib/rfsa/adsp/cdsp/` (and `/usr/lib/dsp/cdsp/`).
   * From `vendor` (`super_7.img` -> `/etc/ASR_binary/Whisper/libQnnHtpV79Skel.so`): copy `libQnnHtpV79Skel.so` into `/usr/lib/rfsa/adsp/cdsp/` and restart `cdsprpcd`.
3. **Mandatory Kernel Config & CMA Memory Pool:**
   * Default Zaviya kernels enable `CONFIG_QCOM_FASTRPC=y` but disable DMA-BUF heaps, causing `FASTRPC_IOCTL_INVOKE` to fail with `ENOMEM`. Rebuild with:
     ```kconfig
     CONFIG_DMABUF_HEAPS=y
     CONFIG_DMABUF_HEAPS_SYSTEM=y
     CONFIG_DMABUF_HEAPS_CMA=y
     ```
   * Add `cma=1G` to the kernel `cmdline` (or define a `memory-region` for `fastrpc` in DTB) to eliminate `no reserved DMA memory for FASTRPC`.
4. **Inference Stack:**
   * **`llama.cpp` (Hexagon):** Build with `-DGGML_HEXAGON=ON` (`--device HTP0`).
   * **`llama.cpp` (Vulkan / 24 GB RAM):** Build with `-DGGML_VULKAN=ON -DGGML_NATIVE=ON` — Linux has no artificial `CL_DEVICE_MAX_MEM_ALLOC_SIZE` cap, exposing the full 24 GB LPDDR5X pool.
