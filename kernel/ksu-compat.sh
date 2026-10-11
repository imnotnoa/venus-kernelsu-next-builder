#!/bin/sh
# Fixes for KernelSU Next (legacy) on venus 5.4 kernels. Each fix checks first
# whether it applies, so it is safe on kernels that do not need it.
# Run from the kernel source root, after KernelSU-Next's setup.sh.
set -eu

KSU=KernelSU-Next/kernel
[ -d "$KSU" ] || { echo "ksu-compat: $KSU not found" >&2; exit 1; }

# Some venus 5.4 kernels (Evolution X among them) have the 5.8 rename
# probe_kernel_write() -> copy_to_kernel_nofault() backported. KernelSU Next
# defines a macro with that name for kernels < 5.8, which then mangles the
# declaration in <linux/uaccess.h>. Drop the macro when the kernel already has
# the function.
PM="$KSU/hook/patch_memory.c"
if [ -f "$PM" ] &&
   grep -q "copy_to_kernel_nofault" include/linux/uaccess.h &&
   grep -q "^#define copy_to_kernel_nofault" "$PM"; then
	perl -0pi -e 's/#if LINUX_VERSION_CODE < KERNEL_VERSION\(5, 8, 0\)\n#define copy_to_kernel_nofault\(.*?\n#endif\n//s' "$PM"
	if grep -q "^#define copy_to_kernel_nofault" "$PM"; then
		echo "ksu-compat: could not remove copy_to_kernel_nofault macro from $PM" >&2
		exit 1
	fi
	echo "ksu-compat: using the kernel's own copy_to_kernel_nofault()"
fi
