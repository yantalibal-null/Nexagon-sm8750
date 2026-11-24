#!/system/bin/sh
# Runs at the post-fs-data stage (before zygote starts)
# Spoofs SoC properties so android.os.Build reports a full Snapdragon 8 Elite (QTI SM8750)

resetprop ro.soc.manufacturer QTI
resetprop ro.soc.model SM8750
resetprop ro.vendor.qti.soc_model SM8750
resetprop ro.vendor.qti.soc_id 618
