#!/bin/bash
# ==========================================================================
# SUSFS v2.1 Compatibility Fixup — Multi-Layout Support
# ==========================================================================
# Handles both NEW layout (KernelSU-Next, Sukisu, ReSukiSU) and
# OLD layout (MamboSU, original KernelSU forks).
# ==========================================================================
set -e

KSU_KERNEL="$1"
if [ -z "$KSU_KERNEL" ] || [ ! -d "$KSU_KERNEL" ]; then
    echo "Usage: $0 <path-to-ksu/kernel>"
    exit 1
fi

# ==========================================
# Layout Detection
# ==========================================
KBUILD="$KSU_KERNEL/Kbuild"
if [ -d "$KSU_KERNEL/core" ]; then
    LAYOUT="NEW"
    # NEW layout paths
    INIT_C="$KSU_KERNEL/core/init.c"
    SUCOMPAT_C="$KSU_KERNEL/feature/sucompat.c"
    SUCOMPAT_H="$KSU_KERNEL/feature/sucompat.h"
    SETUID_HOOK_C="$KSU_KERNEL/hook/setuid_hook.c"
    BRIDGE_C="$KSU_KERNEL/hook/syscall_event_bridge.c"
    SUPERCALL_C="$KSU_KERNEL/supercall/supercall.c"
    SUPERCALL_H="$KSU_KERNEL/supercall/supercall.h"
    KSUD_H="$KSU_KERNEL/runtime/ksud.h"
    KSUD_INT_C="$KSU_KERNEL/runtime/ksud_integration.c"
    APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
    KUMOUNT_C="$KSU_KERNEL/feature/kernel_umount.c"
    KSU_H="$KSU_KERNEL/include/ksu.h"
    RULES_C="$KSU_KERNEL/selinux/rules.c"
    SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
else
    LAYOUT="OLD"
    # OLD layout paths (flat)
    INIT_C="$KSU_KERNEL/ksu.c"
    SUCOMPAT_C="$KSU_KERNEL/sucompat.c"
    SUCOMPAT_H="$KSU_KERNEL/sucompat.h"
    SETUID_HOOK_C="$KSU_KERNEL/setuid_hook.c"
    SUPERCALL_C="$KSU_KERNEL/supercalls.c"
    KSUD_C="$KSU_KERNEL/ksud.c"
    KSUD_H="$KSU_KERNEL/ksud.h"
    KUMOUNT_C="$KSU_KERNEL/kernel_umount.c"
    KSU_H="$KSU_KERNEL/ksu.h"
    RULES_C="$KSU_KERNEL/selinux/rules.c"
    SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
fi

echo "[SUSFS-Fixup] Layout: $LAYOUT"
echo "[SUSFS-Fixup] Starting compatibility fixups..."

# ==========================================
# SHARED: Makefile — Add SUSFS version detection
# ==========================================
MAKEFILE="$KSU_KERNEL/Makefile"
if [ -f "$MAKEFILE" ] && ! grep -q "SUSFS_VERSION" "$MAKEFILE" 2>/dev/null; then
    cat >> "$MAKEFILE" << 'MKEOF'

## For susfs stuff ##
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info )
$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
else
$(info -- You have not integrated susfs in your kernel yet.)
endif
MKEOF
    echo "[SUSFS-Fixup] Makefile: Added SUSFS version detection"
fi

# ==========================================
# SHARED: init — Ensure susfs include + init call
# ==========================================
if [ -f "$INIT_C" ]; then
    if ! grep -q "linux/susfs.h" "$INIT_C" 2>/dev/null; then
        sed -i '/#include <linux\/workqueue.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '/#include <linux\/moduleparam.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || true
    fi
    if ! grep -q "susfs_init()" "$INIT_C" 2>/dev/null; then
        sed -i '/ksu_file_wrapper_init/a\\n\tsusfs_init();' "$INIT_C" 2>/dev/null || true
    fi
    echo "[SUSFS-Fixup] init: susfs include + init call OK"
fi

# ==========================================
# SHARED: selinux/rules.c — Add susfs SID init calls
# ==========================================
if [ -f "$RULES_C" ] && ! grep -q "susfs_set_zygote_sid" "$RULES_C" 2>/dev/null; then
    if [ -f "$SELINUX_H" ]; then
        # Ensure declarations exist
        for fn in susfs_set_init_sid susfs_set_ksu_sid susfs_set_zygote_sid; do
            grep -q "$fn" "$SELINUX_H" 2>/dev/null || \
                sed -i "/^#endif/i void ${fn}(void);" "$SELINUX_H"
        done
    fi
    # Add calls before the reset_avc_cache() CALL only
    if grep -q "reset_avc_cache();" "$RULES_C" 2>/dev/null; then
        sed -i 's/^[ \t]*reset_avc_cache();/\tsusfs_set_init_sid();\n\tsusfs_set_ksu_sid();\n\tsusfs_set_zygote_sid();\n\treset_avc_cache();/' "$RULES_C"
    fi
    echo "[SUSFS-Fixup] selinux/rules.c: Added susfs SID init calls"
fi

# ==========================================
# SHARED: sucompat — Add ksu_handle_execveat_init()
# ==========================================
if [ -f "$SUCOMPAT_C" ] && ! grep -q "ksu_handle_execveat_init" "$SUCOMPAT_C" 2>/dev/null; then
    # Add susfs_def.h include
    if ! grep -q "linux/susfs_def.h" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '1,/#include/{/#include/a #include <linux/susfs_def.h>
        }' "$SUCOMPAT_C" 2>/dev/null || true
    fi

    cat >> "$SUCOMPAT_C" << 'SUCOMPAT_EOF'

#ifdef CONFIG_KSU_SUSFS
int ksu_handle_execveat_init(struct filename *filename,
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    if (current->pid != 1 && is_init(get_current_cred())) {
        if (unlikely(strcmp(filename->name, KSUD_PATH) == 0)) {
            pr_info("hook_manager: escape to root for init executing ksud: %d\n", current->pid);
            escape_to_root_for_init();
            return 0;
        } else if (likely(strstr(filename->name, "/app_process") == NULL &&
                    strstr(filename->name, "/adbd") == NULL) &&
                    !susfs_is_current_proc_umounted())
        {
            pr_info("susfs: mark no sucompat checks for pid: '%d', exec: '%s'\n",
                current->pid, filename->name);
            susfs_set_current_proc_umounted();
            return 0;
        }
        return 0;
    }
    return -EINVAL;
}
#endif /* CONFIG_KSU_SUSFS */
SUCOMPAT_EOF
    echo "[SUSFS-Fixup] sucompat: Added ksu_handle_execveat_init()"
fi

# Add declaration to header
if [ -f "$SUCOMPAT_H" ] && ! grep -q "ksu_handle_execveat_init" "$SUCOMPAT_H" 2>/dev/null; then
    if [ "$LAYOUT" == "NEW" ]; then
        sed -i '/^#endif/i \
#ifdef CONFIG_KSU_SUSFS\
#include <linux/fs.h>\
#include "runtime/ksud.h"\
int ksu_handle_execveat_init(struct filename *filename,\
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user);\
#endif' "$SUCOMPAT_H"
    fi
fi

# ==========================================
# SHARED: setuid_hook — Add do_umount label if needed
# ==========================================
if [ -f "$SETUID_HOOK_C" ] && grep -q "goto do_umount;" "$SETUID_HOOK_C" 2>/dev/null; then
    if ! grep -q "do_umount:" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount/i\\ndo_umount:' "$SETUID_HOOK_C"
        echo "[SUSFS-Fixup] setuid_hook: Added do_umount label"
    fi
fi

# ==========================================
# NEW LAYOUT ONLY: Fixes specific to KernelSU-Next architecture
# ==========================================
if [ "$LAYOUT" == "NEW" ]; then

    # Kbuild: Keep existing hook objects (patch hunk correctly failed)
    echo "[SUSFS-Fixup] Kbuild: No changes needed (keeping hook objects)"

    # sucompat.h — version include
    if [ -f "$SUCOMPAT_H" ] && ! grep -q "linux/version.h" "$SUCOMPAT_H" 2>/dev/null; then
        sed -i '/#include <linux\/types.h>/a #include <linux/version.h>' "$SUCOMPAT_H"
    fi

    # tp_marker.h include for setuid_hook
    if [ -f "$SETUID_HOOK_C" ] && grep -q "ksu_set_task_tracepoint_flag" "$SETUID_HOOK_C" 2>/dev/null; then
        if ! grep -q "hook/tp_marker.h" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/#include "hook\/setuid_hook.h"/a #include "hook/tp_marker.h"' "$SETUID_HOOK_C"
        fi
    fi

    # syscall_event_bridge.c: Fix setresuid 2-arg → 3-arg call
    if [ -f "$BRIDGE_C" ] && grep -q "ksu_handle_setresuid(old_uid, current_uid().val)" "$BRIDGE_C" 2>/dev/null; then
        sed -i 's/ksu_handle_setresuid(old_uid, current_uid()\.val);/{\
        uid_t ruid = PT_REGS_PARM1(regs);\
        uid_t euid = PT_REGS_PARM2(regs);\
        uid_t suid = PT_REGS_PARM3(regs);\
        ksu_handle_setresuid(ruid, euid, suid);\
    }/' "$BRIDGE_C"
        echo "[SUSFS-Fixup] syscall_event_bridge: Fixed setresuid 3-arg call"
    fi

    # supercall.c: Add ksu_supercall_reboot_handler()
    if [ -f "$SUPERCALL_C" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_C" 2>/dev/null; then
        cat >> "$SUPERCALL_C" << 'SUPERCALL_EOF'

int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;
    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw) return 0;
    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;
    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\n");
    }
    return 0;
}
SUPERCALL_EOF
        echo "[SUSFS-Fixup] supercall: Added ksu_supercall_reboot_handler"
    fi

    if [ -f "$SUPERCALL_H" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_H" 2>/dev/null; then
        sed -i '/int ksu_install_fd(void);/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H"
    fi

    # ksu_late_loaded restoration
    if grep -q "ksu_late_loaded" "$INIT_C" 2>/dev/null; then
        if ! grep -q "bool ksu_late_loaded" "$INIT_C" 2>/dev/null; then
            sed -i '/^struct cred \*ksu_cred;/a bool ksu_late_loaded;' "$INIT_C"
        fi
        if ! grep -q "extern bool ksu_late_loaded" "$KSU_H" 2>/dev/null; then
            sed -i '/^extern struct cred \*ksu_cred;/a extern bool ksu_late_loaded;' "$KSU_H"
        fi
    fi

    # ksud compatibility wrappers (for syscall_event_bridge.c calling old API)
    if [ -f "$KSUD_INT_C" ] && ! grep -q "ksu_execve_hook_ksud" "$KSUD_INT_C" 2>/dev/null; then
        # Add declaration to ksud.h
        if [ -f "$KSUD_H" ] && ! grep -q "ksu_execve_hook_ksud" "$KSUD_H" 2>/dev/null; then
            if grep -q "ksu_handle_execveat_ksud" "$KSUD_H" 2>/dev/null; then
                sed -i '/ksu_handle_execveat_ksud/,/;/{/;/a\
\
void ksu_execve_hook_ksud(const struct pt_regs *regs);\
void ksu_stop_input_hook_runtime(void);
}' "$KSUD_H"
            fi
        fi

        cat >> "$KSUD_INT_C" << 'KSUD_COMPAT_EOF'

/* Compatibility wrapper — syscall_event_bridge.c calls old pt_regs API */
extern void ksu_stop_ksud_execve_hook(void);

void ksu_execve_hook_ksud(const struct pt_regs *regs)
{
    const char __user **filename_user_p = (const char __user **)&PT_REGS_PARM1(regs);
    const char __user *const __user *__argv = (const char __user *const __user *)PT_REGS_PARM2(regs);
    struct user_arg_ptr argv = { .ptr.native = __argv };
    char path[256];
    long ret;
    unsigned long addr;
    const char __user *fn;

    static const char app_process[] = "/system/bin/app_process";
    static bool first_zygote = true;
    static const char system_bin_init[] = "/system/bin/init";
    static bool init_second_stage_executed = false;

    if (!filename_user_p) return;
    addr = untagged_addr((unsigned long)*filename_user_p);
    fn = (const char __user *)addr;
    memset(path, 0, sizeof(path));
    ret = strncpy_from_user(path, fn, sizeof(path) - 1);
    if (ret <= 0) return;

    if (unlikely(!memcmp(path, system_bin_init, sizeof(system_bin_init) - 1) && __argv)) {
        char buf[16];
        if (!init_second_stage_executed &&
            check_argv(argv, 1, "second_stage", buf, sizeof(buf))) {
            pr_info("/system/bin/init second_stage executed\n");
            apply_kernelsu_rules();
            cache_sid();
            setup_ksu_cred();
            init_second_stage_executed = true;
        }
    }

    if (unlikely(first_zygote && !memcmp(path, app_process, sizeof(app_process) - 1) && __argv)) {
        char buf[16];
        if (check_argv(argv, 1, "-Xzygote", buf, sizeof(buf))) {
            pr_info("exec zygote, /data prepared, second_stage: %d\n", init_second_stage_executed);
            on_post_fs_data();
            first_zygote = false;
            ksu_stop_ksud_execve_hook();
        }
    }

#ifdef CONFIG_KSU_SUSFS
    {
        struct filename fname;
        fname.name = path;
        (void)ksu_handle_execveat_init(&fname, &argv, NULL);
    }
#endif
}

void ksu_stop_input_hook_runtime(void)
{
    extern bool ksu_input_hook;
    ksu_input_hook = false;
    pr_info("ksu_input_hook: %d\n", ksu_input_hook);
}
KSUD_COMPAT_EOF
        echo "[SUSFS-Fixup] ksud: Added compatibility wrappers"
    fi

    # Fix for Sukisu/Custom roots: Remove undefined symbol references if hook objects are not compiled
    if [ -f "$KBUILD" ]; then
        if ! grep -q "tp_marker.o" "$KBUILD" 2>/dev/null && [ -f "$APP_PROFILE_C" ]; then
            sed -i '/ksu_set_task_tracepoint_flag/d' "$APP_PROFILE_C"
            sed -i '/ksu_clear_task_tracepoint_flag/d' "$APP_PROFILE_C"
            echo "[SUSFS-Fixup] app_profile: Removed tracepoint calls (tp_marker.o not compiled)"
        fi
        if ! grep -q "syscall_event_bridge.o" "$KBUILD" 2>/dev/null && [ -f "$KSUD_INT_C" ]; then
            sed -i '/extern void ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C"
            sed -i '/ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C"
            echo "[SUSFS-Fixup] ksud_integration: Removed execve_hook stop calls (syscall_event_bridge.o not compiled)"
        fi
    fi

    # Fix extern ksu_handle_execveat_init → use include
    if [ -f "$KSUD_INT_C" ] && grep -q "extern int ksu_handle_execveat_init" "$KSUD_INT_C" 2>/dev/null; then
        if ! grep -q "feature/sucompat.h" "$KSUD_INT_C" 2>/dev/null; then
            sed -i '/#include "selinux\/selinux.h"/a #include "feature/sucompat.h"' "$KSUD_INT_C"
        fi
        sed -i '/^extern int ksu_handle_execveat_init/d' "$KSUD_INT_C"
    fi

fi # END NEW LAYOUT

# ==========================================
# OLD LAYOUT ONLY: Fixes specific to MamboSU/original KernelSU
# ==========================================
if [ "$LAYOUT" == "OLD" ]; then

    # ksu.c: Replace syscall_hook_manager_init with separate hooks
    if [ -f "$INIT_C" ] && grep -q "ksu_syscall_hook_manager_init" "$INIT_C" 2>/dev/null; then
        if ! grep -q "ksu_sucompat_init" "$INIT_C" 2>/dev/null; then
            sed -i 's/ksu_syscall_hook_manager_init();/#ifndef CONFIG_KSU_SUSFS\
    ksu_syscall_hook_manager_init();\
#else\
    ksu_setuid_hook_init();\
    ksu_sucompat_init();\
#endif/' "$INIT_C"
            echo "[SUSFS-Fixup] ksu.c: Wrapped hook init for SUSFS"
        fi
    fi

    # ksu.c exit: Replace syscall_hook_manager_exit
    if [ -f "$INIT_C" ] && grep -q "ksu_syscall_hook_manager_exit" "$INIT_C" 2>/dev/null; then
        if ! grep -q "ksu_sucompat_exit" "$INIT_C" 2>/dev/null; then
            sed -i 's/ksu_syscall_hook_manager_exit();/#ifndef CONFIG_KSU_SUSFS\
    ksu_syscall_hook_manager_exit();\
#else\
    ksu_setuid_hook_exit();\
    ksu_sucompat_exit();\
#endif/' "$INIT_C"
            echo "[SUSFS-Fixup] ksu.c: Wrapped hook exit for SUSFS"
        fi
    fi

    # ksu.c: Wrap syscall_hook_manager.h include with CONFIG_KSU_SUSFS guard
    # and add SUSFS alternative includes. Also wrap init/exit calls.
    if [ -f "$INIT_C" ] && grep -q '#include "syscall_hook_manager.h"' "$INIT_C" 2>/dev/null; then
        # Wrap the include with #ifndef/#else/#endif
        if ! grep -q 'CONFIG_KSU_SUSFS' "$INIT_C" 2>/dev/null; then
            sed -i 's|^#include "syscall_hook_manager.h"|#ifndef CONFIG_KSU_SUSFS\n#include "syscall_hook_manager.h"\n#else\n#include "setuid_hook.h"\n#include "sucompat.h"\n#endif // #ifndef CONFIG_KSU_SUSFS|' "$INIT_C"
            # Wrap ksu_syscall_hook_manager_init() call
            sed -i 's|^\(\s*\)ksu_syscall_hook_manager_init();|\1#ifndef CONFIG_KSU_SUSFS\n\1ksu_syscall_hook_manager_init();\n\1#else\n\1ksu_setuid_hook_init();\n\1ksu_sucompat_init();\n\1#endif|' "$INIT_C"
            # Wrap ksu_syscall_hook_manager_exit() call
            sed -i 's|^\(\s*\)ksu_syscall_hook_manager_exit();|\1#ifndef CONFIG_KSU_SUSFS\n\1ksu_syscall_hook_manager_exit();\n\1#endif|' "$INIT_C"
            # Add susfs.h include if not already present
            if ! grep -q 'linux/susfs.h' "$INIT_C" 2>/dev/null; then
                sed -i '/#include <linux\/fs.h>/a\
#include <linux\/susfs.h>' "$INIT_C"
            fi
            echo "[SUSFS-Fixup] ksu.c: Wrapped syscall_hook_manager with CONFIG_KSU_SUSFS guards"
        fi
    fi

    # ksud.c: Revert catastrophic patch damage on OLD layout (MamboSU removes hooks entirely)
    if [ -f "$KSUD_C" ] && grep -q "ksu_init_rc_hook" "$KSUD_C" 2>/dev/null; then
        (cd "$KSU_KERNEL/.." && git checkout kernel/ksud.c 2>/dev/null || true)
        # The patch injected user_arg_ptr into ksud.h, so we must remove the native definition from ksud.c to avoid redefinition
        sed -i '/^struct user_arg_ptr {/,/^};/d' "$KSUD_C"
        echo "[SUSFS-Fixup] ksud.c: Reverted patch damage (MamboSU uses native hooks)"
    fi

    # supercalls.c: Revert to native and surgically inject SUSFS
    # The SUSFS KSU patch causes catastrophic damage to MamboSU's supercalls.c:
    # - It strips ALL #ifndef/#else/#endif guards, breaking ksys_close/close_fd version checks
    # - It re-exposes calls to syscall_hook_manager functions that aren't compiled
    # Strategy: revert to clean native source, then inject ONLY what SUSFS needs.
    if [ -f "$SUPERCALL_C" ]; then
        # Revert to pristine native MamboSU source
        (cd "$KSU_KERNEL/.." && git checkout kernel/supercalls.c 2>/dev/null || true)

        # 1. Add SUSFS includes after #include <linux/fs.h>
        if ! grep -q "linux/susfs.h" "$SUPERCALL_C" 2>/dev/null; then
            sed -i '/#include <linux\/fs.h>/a\
#ifdef CONFIG_KSU_SUSFS\
#include <linux\/susfs.h>\
#include <linux\/susfs_def.h>\
static int ksu_susfs_supercall(unsigned int cmd, void __user **arg);\
#endif' "$SUPERCALL_C"
        fi

        # 2. Add SUSFS magic check inside ksu_handle_sys_reboot (before native magic check)
        if ! grep -q "SUSFS_MAGIC" "$SUPERCALL_C" 2>/dev/null; then
            sed -i '/if (magic1 != KSU_INSTALL_MAGIC1)/i\
#ifdef CONFIG_KSU_SUSFS\
    if (magic2 == SUSFS_MAGIC \&\& current_uid().val == 0) {\
        return ksu_susfs_supercall(cmd, arg);\
    }\
#endif' "$SUPERCALL_C"
        fi

        # Stubs are NOT needed — syscall_hook_manager.c IS compiled for MamboSU
        # (unlike what we initially assumed). Only the SUSFS handler is needed.
        cat >> "$SUPERCALL_C" << 'SUSFS_MAMBOSU_EOF'

/* =================================================================== *
 * SUSFS v2.1 Compatibility Layer for MamboSU
 * Injected by ksu_susfs_fixup.sh - DO NOT EDIT MANUALLY
 * =================================================================== */
#ifdef CONFIG_KSU_SUSFS

/* SUSFS supercall dispatch handler */
static int ksu_susfs_supercall(unsigned int cmd, void __user **arg)
{
    switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
    case CMD_SUSFS_ADD_SUS_PATH:
        susfs_add_sus_path(arg);
        break;
    case CMD_SUSFS_ADD_SUS_PATH_LOOP:
        susfs_add_sus_path_loop(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
    case CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
        susfs_set_hide_sus_mnts_for_non_su_procs(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
    case CMD_SUSFS_ADD_SUS_KSTAT:
        susfs_add_sus_kstat(arg);
        break;
    case CMD_SUSFS_UPDATE_SUS_KSTAT:
        susfs_update_sus_kstat(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
    case CMD_SUSFS_SET_UNAME:
        susfs_set_uname(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
    case CMD_SUSFS_ENABLE_LOG:
        susfs_enable_log(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
        susfs_set_cmdline_or_bootconfig(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
    case CMD_SUSFS_ADD_OPEN_REDIRECT:
        susfs_add_open_redirect(arg);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
    case CMD_SUSFS_ADD_SUS_MAP:
        susfs_add_sus_map(arg);
        break;
#endif
    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
        susfs_set_avc_log_spoofing(arg);
        break;
    case CMD_SUSFS_SHOW_ENABLED_FEATURES:
        susfs_get_enabled_features(arg);
        break;
    case CMD_SUSFS_SHOW_VARIANT:
        susfs_show_variant(arg);
        break;
    case CMD_SUSFS_SHOW_VERSION:
        susfs_show_version(arg);
        break;
    default:
        pr_info("susfs: no handler for cmd: 0x%x\n", cmd);
        break;
    }
    return 0;
}

#endif /* CONFIG_KSU_SUSFS */
SUSFS_MAMBOSU_EOF

        echo "[SUSFS-Fixup] supercalls.c: Reverted + injected SUSFS handler and stubs"
    fi

    # sucompat.h: Fix 3-argument signature if present
    if [ -f "$SUCOMPAT_H" ] && grep -q "struct user_arg_ptr \*argv_user" "$SUCOMPAT_H" 2>/dev/null; then
        sed -i 's/int ksu_handle_execveat_init(struct filename \*filename,/int ksu_handle_execveat_init(struct filename \*filename);/g' "$SUCOMPAT_H"
        sed -i '/struct user_arg_ptr \*argv_user, struct user_arg_ptr \*envp_user);/d' "$SUCOMPAT_H"
        echo "[SUSFS-Fixup] sucompat.h: Fixed ksu_handle_execveat_init signature to 1-arg"
    fi

    # ksud.c: fix extern ksu_handle_execveat_init if wrong signature
    if [ -f "$KSUD_C" ] && grep -q "extern int ksu_handle_execveat_init(struct filename \*filename)" "$KSUD_C" 2>/dev/null; then
        # OLD layout uses single-arg version — patch it to include the header instead
        if [ -f "$SUCOMPAT_H" ] && ! grep -q '"sucompat.h"' "$KSUD_C" 2>/dev/null; then
            sed -i '/#include "ksud.h"/a #include "sucompat.h"' "$KSUD_C"
        fi
        sed -i '/^extern int ksu_handle_execveat_init/d' "$KSUD_C"
        echo "[SUSFS-Fixup] ksud.c: Fixed extern → include for ksu_handle_execveat_init"
    fi

fi # END OLD LAYOUT

echo "[SUSFS-Fixup] All compatibility fixups applied successfully!"
