// SPDX-License-Identifier: GPL-2.0-only
/*
 * Common crypto library for storage encryption.
 *
 * Copyright (c) 2022-2023, 2025 Qualcomm Innovation Center, Inc. All rights reserved.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/crypto-qti-common.h>
#include "crypto-qti-ice-regs.h"
#include "crypto-qti-platform.h"

#define QCOM_ICE_HWKM_REG_OFFSET	0x8000

static int get_mmio_data(struct ice_mmio_data *data, void __iomem *base)
{
	if (!base) {
		pr_err("%s: ICE value invalid\n", __func__);
		return -EINVAL;
	}
	data->ice_base_mmio = base;
	data->ice_hwkm_mmio = base + QCOM_ICE_HWKM_REG_OFFSET;

	return 0;
}

int crypto_qti_keyslot_program(void __iomem *base,
			       const struct blk_crypto_key *key,
			       unsigned int slot,
			       u8 data_unit_mask, int capid, int storage_type)
{
	int err = 0;
	struct ice_mmio_data mmio_data;

	err = get_mmio_data(&mmio_data, base);
	if (err)
		return err;

	err = crypto_qti_program_key(&mmio_data, key, slot,
				data_unit_mask, capid, storage_type);
	if (err) {
		pr_err("%s: program key failed with error %d\n", __func__, err);
		err = crypto_qti_invalidate_key(&mmio_data, slot, storage_type);
		if (err)
			pr_err("%s: invalidate key failed with error %d\n", __func__, err);
	}

	return err;
}
EXPORT_SYMBOL_GPL(crypto_qti_keyslot_program);

int crypto_qti_keyslot_evict(void __iomem *base,
			     unsigned int slot, int storage_type)
{
	int err = 0;
	struct ice_mmio_data mmio_data;

	err = get_mmio_data(&mmio_data, base);
	if (err)
		return err;

	err = crypto_qti_invalidate_key(&mmio_data, slot, storage_type);
	if (err)
		pr_err("%s: invalidate key failed with error %d\n", __func__, err);

	return err;
}
EXPORT_SYMBOL_GPL(crypto_qti_keyslot_evict);

int crypto_qti_derive_raw_secret(const u8 *wrapped_key,
				 unsigned int wrapped_key_size, u8 *secret,
				 unsigned int secret_size)
{
	int err = 0;

	if (wrapped_key_size <= RAW_SECRET_SIZE) {
		pr_err("%s: Invalid wrapped_key_size: %u\n",
				__func__, wrapped_key_size);
		err = -EINVAL;
		return err;
	}
	if (secret_size != RAW_SECRET_SIZE) {
		pr_err("%s: Invalid secret size: %u\n", __func__, secret_size);
		err = -EINVAL;
		return err;
	}

	if (wrapped_key_size > 64)
		err = crypto_qti_derive_raw_secret_platform(wrapped_key,
				wrapped_key_size, secret, secret_size);
	else
		memcpy(secret, wrapped_key, secret_size);

	return err;
}
EXPORT_SYMBOL_GPL(crypto_qti_derive_raw_secret);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("QTI Common crypto library for storage encryption");
