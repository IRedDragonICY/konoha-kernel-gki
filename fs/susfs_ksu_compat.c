// SPDX-License-Identifier: GPL-2.0

#include <linux/compiler.h>
#include <linux/fs.h>
#include <linux/mutex.h>
#include <linux/susfs.h>
#include <linux/types.h>

/*
 * SUSFS patches in this tree reference legacy KernelSU hook symbols that may
 * not be exported by newer KernelSU-Next revisions. Provide weak fallback
 * symbols so builds remain linkable, while allowing real implementations to
 * override these when present.
 */

extern bool is_ksu_domain(void) __weak;

#ifndef KSU_INSTALL_MAGIC1
#define KSU_INSTALL_MAGIC1 0xDEADBEEF
#endif

static DEFINE_MUTEX(susfs_bootstrap_lock);
static bool susfs_bootstrap_done __read_mostly;

static void susfs_bootstrap_once(void)
{
       if (READ_ONCE(susfs_bootstrap_done))
              return;

       mutex_lock(&susfs_bootstrap_lock);
       if (!susfs_bootstrap_done) {
              susfs_init();
              susfs_start_sdcard_monitor_fn();
              WRITE_ONCE(susfs_bootstrap_done, true);
       }
       mutex_unlock(&susfs_bootstrap_lock);
}

u32 susfs_ksu_sid __read_mostly __weak;
u32 susfs_priv_app_sid __read_mostly __weak;

int __weak ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
                                void __user **arg)
{
       if ((u32)magic1 != KSU_INSTALL_MAGIC1 || (u32)magic2 != SUSFS_MAGIC)
              return 1;

       susfs_bootstrap_once();

       switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
       case CMD_SUSFS_ADD_SUS_PATH:
              susfs_add_sus_path(arg);
              return 0;
       case CMD_SUSFS_ADD_SUS_PATH_LOOP:
              susfs_add_sus_path_loop(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
       case CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
              susfs_set_hide_sus_mnts_for_non_su_procs(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
       case CMD_SUSFS_ADD_SUS_KSTAT:
       case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
              susfs_add_sus_kstat(arg);
              return 0;
       case CMD_SUSFS_UPDATE_SUS_KSTAT:
              susfs_update_sus_kstat(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
       case CMD_SUSFS_SET_UNAME:
              susfs_set_uname(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
       case CMD_SUSFS_ENABLE_LOG:
              susfs_enable_log(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
       case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
              susfs_set_cmdline_or_bootconfig(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
       case CMD_SUSFS_ADD_OPEN_REDIRECT:
              susfs_add_open_redirect(arg);
              return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
       case CMD_SUSFS_ADD_SUS_MAP:
              susfs_add_sus_map(arg);
              return 0;
#endif
       case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
              susfs_set_avc_log_spoofing(arg);
              return 0;
       case CMD_SUSFS_SHOW_ENABLED_FEATURES:
              susfs_get_enabled_features(arg);
              return 0;
       case CMD_SUSFS_SHOW_VARIANT:
              susfs_show_variant(arg);
              return 0;
       case CMD_SUSFS_SHOW_VERSION:
              susfs_show_version(arg);
              return 0;
       default:
              return 1;
       }
}

void __weak ksu_handle_sys_read(unsigned int fd)
{
}

void __weak ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
}

int __weak ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                              void *argv, void *envp, int *flags)
{
       return 0;
}

int __weak ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                                       void *argv, void *envp, int *flags)
{
       return 0;
}

int __weak ksu_handle_devpts(struct inode *inode)
{
       return 0;
}

int __weak ksu_handle_input_handle_event(unsigned int *type,
                                        unsigned int *code, int *value)
{
       return 0;
}

bool __weak susfs_is_current_ksu_domain(void)
{
       if (is_ksu_domain)
               return is_ksu_domain();

       return false;
}
