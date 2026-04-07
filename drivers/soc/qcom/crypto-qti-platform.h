/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2022-2023, 2025 Qualcomm Innovation Center, Inc. All rights reserved.
 */

#ifndef _CRYPTO_QTI_PLATFORM_H
#define _CRYPTO_QTI_PLATFORM_H

#include <linux/blk-crypto.h>
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/device.h>

int crypto_qti_program_key(const struct ice_mmio_data *mmio_data,
			   const struct blk_crypto_key *key,
			   unsigned int slot,
			   unsigned int data_unit_mask, int capid, int storage_type);
int crypto_qti_invalidate_key(const struct ice_mmio_data *mmio_data,
			      unsigned int slot, int storage_type);
int crypto_qti_derive_raw_secret_platform(
				const u8 *wrapped_key,
				unsigned int wrapped_key_size, u8 *secret,
				unsigned int secret_size);
#endif /* _CRYPTO_QTI_PLATFORM_H */
