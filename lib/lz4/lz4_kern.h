/* SPDX-License-Identifier: GPL-2.0 */
/* Kernel allocation hooks for LZ4 */

#ifndef __LZ4_KERN_H__
#define __LZ4_KERN_H__

#include <linux/slab.h>  /* for kmalloc, kzalloc, kfree, GFP_KERNEL */

#define ALLOC(sz)          kmalloc((sz), GFP_KERNEL)
#define ALLOC_AND_ZERO(sz) kzalloc((sz), GFP_KERNEL)
#define FREEMEM(p)         kfree((p))

#endif /* __LZ4_KERN_H__ */
