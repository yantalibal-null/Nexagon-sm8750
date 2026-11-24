#!/system/bin/sh
# Runs at late_start service stage
# Brings up Hexagon V79 CDSP, configures FastRPC/QNN permissions, and spoofs sysfs SoC IDs

MOD_DIR="/data/local/tmp/npu_unlock"
mkdir -p "$MOD_DIR"

# 1. Spoof kernel sysfs SoC identifiers for native C++/JNI libraries
echo -n "618" > "$MOD_DIR/fake_soc_id"
echo -n "SM8750" > "$MOD_DIR/fake_machine"
mount --bind "$MOD_DIR/fake_soc_id" /sys/devices/soc0/soc_id
mount --bind "$MOD_DIR/fake_machine" /sys/devices/soc0/machine

# 2. Load kCFI-compatible kernel module to enable /soc/remoteproc-cdsp@32300000
insmod "$MOD_DIR/enable_cdsp_clean.ko"

# 3. Bind-mount the unsigned Hexagon V79 skeleton to the standard DSP search path
if [ -f /vendor/etc/ASR_binary/Whisper/libQnnHtpV79Skel.so ]; then
    mount --bind /vendor/etc/ASR_binary/Whisper/libQnnHtpV79Skel.so /vendor/dsp/cdsp/libQnnHtpV79Skel.so
fi

# 4. Grant access to FastRPC and DMA-BUF nodes for user applications
sleep 2
chmod 0666 /dev/fastrpc-cdsp* /dev/dma_heap/system 2>/dev/null

# 5. Live SELinux policy rules allowing untrusted_app to access Hexagon NPU
magiskpolicy --live "allow untrusted_app adsprpcd_file dir { read open search getattr }"
magiskpolicy --live "allow untrusted_app adsprpcd_file file { read open getattr map execute }"
magiskpolicy --live "allow untrusted_app dmabuf_system_heap_device chr_file { read write open ioctl map }"
magiskpolicy --live "allow untrusted_app fastrpc_device chr_file { read write open ioctl map }"
