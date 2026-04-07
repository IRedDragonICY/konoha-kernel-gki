/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2022-2023, 2025 Qualcomm Innovation Center, Inc. All rights reserved.
 */

#ifndef _CRYPTO_QTI_COMMON_H
#define _CRYPTO_QTI_COMMON_H

#include <linux/blk-crypto.h>
#include <linux/types.h>
#include <linux/device.h>
#include <linux/platform_device.h>

#define RAW_SECRET_SIZE 32

/* Storage types for crypto */
#define UFS_CE 10
#define SDCC_CE 20

struct ice_mmio_data {
	void __iomem *ice_base_mmio;
	void __iomem *ice_hwkm_mmio;
	struct device *dev;
	void __iomem *km_base;
	struct resource *km_res;
	struct list_head clk_list_head;
	bool is_hwkm_clk_available;
	bool is_hwkm_enabled;
};

int crypto_qti_keyslot_program(void __iomem *base,
			       const struct blk_crypto_key *key,
			       unsigned int slot, u8 data_unit_mask,
			       int capid, int storage_type);
int crypto_qti_keyslot_evict(void __iomem *base,
			     unsigned int slot, int storage_type);
int crypto_qti_derive_raw_secret(const u8 *wrapped_key,
				 unsigned int wrapped_key_size, u8 *secret,
				 unsigned int secret_size);

#endif /* _CRYPTO_QTI_COMMON_H */
