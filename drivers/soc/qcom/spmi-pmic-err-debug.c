// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
 */

#include <linux/delay.h>
#include <linux/err.h>
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spmi.h>

/* SPMI CNFG register offsets: */
#define SPMI_PROTOCOL_IRQ_STATUS	0x2000
#define SPMI_PROTOCOL_IRQ_ENABLE	0x2004
#define SPMI_PROTOCOL_IRQ_CLEAR		0x2008
#define SPMI_PROTOCOL_IRQ_EN_SET	0x200C
#define SPMI_PROTOCOL_IRQ_EN_CLEAR	0x2010
#define SPMI_TEST_BUS_CTRL		0x3000
#define SPMI_DEBUG_REG			0x3028

/* SPMI GENI register offsets: */
#define SPMI_GENI_TEST_BUS_CTRL		0x30

#define PROTOCOL_IRQ_DEFAULT_REASONS	0x7BEF
#define PRINT_BUFFER_SIZE		400

/**
 * spmi_pmic_err_debug - SPMI PMIC error debug object
 * @dev:		SPMI PMIC error device pointer
 * @cnfg:		address of PMIC Arbiter configuration registers
 * @geni:		address of PMIC Arbiter geni configuration registers
 * @cnfg_base_addr:	base physical address of PMIC Arbiter configuration registers
 * @geni_base_addr:	base physical address of PMIC Arbiter geni configuration registers
 * @buf_cnfg:		buffer holding SPMI CNFG register data
 * @buf_geni:		buffer holding SPMI GENI register data
 * @buf_cnfg_test:	buffer holding SPMI CNFG test bus register data
 * @buf_geni_test:	buffer holding SPMI GENI test bus register data
 * @irq:		protocol IRQ interrupt
 * @tz_dbg_en:		boolean flag to indicate if TZ invasive debug is enabled
 */
struct spmi_pmic_err_debug {
	struct device	*dev;
	void __iomem	*cnfg;
	void __iomem	*geni;
	phys_addr_t	cnfg_base_addr;
	phys_addr_t	geni_base_addr;
	char buf_cnfg[PRINT_BUFFER_SIZE];
	char buf_geni[PRINT_BUFFER_SIZE];
	char buf_cnfg_test[PRINT_BUFFER_SIZE];
	char buf_geni_test[PRINT_BUFFER_SIZE];
	int		irq;
	bool		tz_dbg_en;
};

static const u32 reg_array_cnfg[] = {
	0x1804,
	0x1808,
	0x1810,
	0x1814,
	0x1818,
	0x1854,
	0x1C0C,
	0x185C,
	0x2000,
	0x2004,
	0x200C
};

static const u32 reg_array_geni[] = {
	0x0,
	0x10,
	0x14,
	0x18,
	0x1C,
	0x28,
	0x2C,
	0x30,
	0x34,
	0x38,
	0x3C,
	0x40,
	0x44,
	0x48
};

/* Test bus inputs to capture SPMI_GENI_TEST registers */
static const u16 input_array_geni[] = {
	0x0,
	0x2,
	0x3,
	0x4,
	0x5,
	0x6,
	0x7,
	0x8,
	0x9,
	0xA,
	0xB,
	0xC,
	0xD,
	0xE,
	0xF,
	0x10
};

/* Test bus inputs to capture SPMI_TEST registers */
static const u16 input_array_cnfg[] = {
	0x5,
	0x9,
	0xD,
	0x11,
	0x15,
	0x19,
	0x1D,
	0x21,
	0x42,
	0x82,
	0xc2,
	0x102,
	0x142,
	0x182,
	0x1C2,
	0x202,
	0x242
};

static void pmic_arb_read_test_bus_regs(struct spmi_pmic_err_debug *pe, phys_addr_t reg,
					const u16 *input_array, int len, char *buf)
{
	size_t buflen = PRINT_BUFFER_SIZE;
	int i, ret, pos = 0;
	u32 data;

	for (i = 0; i < len; i++) {
		ret = qcom_scm_io_writel(reg, input_array[i]);
		if (ret) {
			dev_err(pe->dev, "scm write to %lld failed, ret = %d\n",
				reg, ret);
			return;
		}
		data = readl_relaxed(pe->cnfg + SPMI_DEBUG_REG);

		pos += scnprintf(buf + pos, buflen - pos,
				"%#x:\t%#x\n",
				input_array[i], data);
	}
	if (pos)
		buf[pos - 1] = '\0';
}

static void spmi_test_bus_dump_regs(struct spmi_pmic_err_debug *pe, char *buf_cnfg,
				    char *buf_geni)
{
	int ret;

	if (!pe->tz_dbg_en)
		return;

	ret = qcom_scm_io_writel(pe->cnfg_base_addr + SPMI_TEST_BUS_CTRL, 0);
	if (ret) {
		dev_err(pe->dev, "scm write to SPMI_TEST_BUS_CTRL failed, ret = %d\n",
			ret);
		return;
	}

	pmic_arb_read_test_bus_regs(pe, pe->geni_base_addr + SPMI_GENI_TEST_BUS_CTRL,
				    input_array_geni, ARRAY_SIZE(input_array_geni),
				    buf_geni);

	pmic_arb_read_test_bus_regs(pe, pe->cnfg_base_addr + SPMI_TEST_BUS_CTRL,
				    input_array_cnfg, ARRAY_SIZE(input_array_cnfg),
				    buf_cnfg);
}

static void pmic_arb_read_regs(void __iomem *base, phys_addr_t reg, const u32 *reg_array,
				int len, char *buf)
{
	size_t buflen = PRINT_BUFFER_SIZE;
	int i, pos = 0;
	u32 data;

	for (i = 0; i < len; i++) {
		data = readl_relaxed(base + reg_array[i]);
		pos += scnprintf(buf + pos, buflen - pos,
				"%#llx: %#x\n",
				reg + reg_array[i], data);
	}
	if (pos)
		buf[pos - 1] = '\0';
}

static irqreturn_t spmi_protocol_irq_handler(int irq, void *dev_id)
{
	struct spmi_pmic_err_debug *pe = dev_id;

	pmic_arb_read_regs(pe->cnfg, pe->cnfg_base_addr, reg_array_cnfg,
			   ARRAY_SIZE(reg_array_cnfg), pe->buf_cnfg);
	pmic_arb_read_regs(pe->geni, pe->geni_base_addr, reg_array_geni,
			   ARRAY_SIZE(reg_array_geni), pe->buf_geni);

	spmi_test_bus_dump_regs(pe, pe->buf_cnfg_test, pe->buf_geni_test);

	writel_relaxed(PROTOCOL_IRQ_DEFAULT_REASONS, pe->cnfg + SPMI_PROTOCOL_IRQ_CLEAR);

	dev_err(pe->dev, "Dumping SPMI status registers:\n");
	dev_err(pe->dev, "SPMI CNFG registers:\n%s\n", pe->buf_cnfg);
	dev_err(pe->dev, "SPMI GENI registers:\n%s\n", pe->buf_geni);

	dev_err(pe->dev, "Dumping SPMI test bus data:\n");
	dev_err(pe->dev, "SPMI CNFG test bus registers:\n%s\n", pe->buf_cnfg_test);
	dev_err(pe->dev, "SPMI GENI test bus registers:\n%s\n", pe->buf_geni_test);

	return IRQ_HANDLED;
}

static int check_tz_debug_enabled(struct spmi_pmic_err_debug *pe)
{
	struct nvmem_cell *cell;
	u8 *fuse_val;

	cell = nvmem_cell_get(pe->dev, "tz_dbg");
	if (IS_ERR(cell))
		return PTR_ERR(cell);

	fuse_val = nvmem_cell_read(cell, NULL);
	nvmem_cell_put(cell);
	if (IS_ERR(fuse_val))
		return PTR_ERR(fuse_val);

	if (*fuse_val)
		pe->tz_dbg_en = true;
	else
		dev_dbg(pe->dev, "TZ invasive debug disabled by fuse\n");

	kfree(fuse_val);

	return 0;
}

static int spmi_pmic_err_debug_probe(struct platform_device *pdev)
{
	struct spmi_pmic_err_debug *pe;
	struct device *dev = &pdev->dev;
	struct resource *res;
	void __iomem *base;
	int rc;

	pe = devm_kzalloc(dev, sizeof(*pe), GFP_KERNEL);
	if (!pe)
		return -ENOMEM;

	pe->dev = dev;

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "cnfg");
	if (!res)
		return -EINVAL;

	base = devm_ioremap(dev, res->start, resource_size(res));
	if (!base)
		return -ENXIO;

	pe->cnfg = base;
	pe->cnfg_base_addr = res->start;

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "geni");
	if (!res)
		return -EINVAL;

	base = devm_ioremap_resource(dev, res);
	if (IS_ERR(base))
		return PTR_ERR(base);

	pe->geni = base;
	pe->geni_base_addr = res->start;

	pe->irq = platform_get_irq_byname(pdev, "protocol_irq");
	if (pe->irq < 0)
		return pe->irq;

	rc = devm_request_threaded_irq(dev, pe->irq, NULL,
			spmi_protocol_irq_handler, IRQF_ONESHOT,
			"protocol_irq", pe);
	if (rc < 0)
		return dev_err_probe(dev, rc, "Failed to request protocol irq\n");

	/* Check if TZ invasive debug is enabled or disabled by a fuse. */
	if (device_property_present(dev, "nvmem-cells")) {
		rc = check_tz_debug_enabled(pe);
		if (rc)
			return dev_err_probe(dev, rc, "error reading nvmem cell\n");
	}

	writel_relaxed(PROTOCOL_IRQ_DEFAULT_REASONS, pe->cnfg + SPMI_PROTOCOL_IRQ_CLEAR);
	writel_relaxed(PROTOCOL_IRQ_DEFAULT_REASONS, pe->cnfg + SPMI_PROTOCOL_IRQ_EN_SET);

	return 0;
}

static const struct of_device_id spmi_pmic_err_debug_match_table[] = {
	{ .compatible = "qcom,spmi-pmic-err-debug", },
	{},
};
MODULE_DEVICE_TABLE(of, spmi_pmic_err_debug_match_table);

static struct platform_driver spmi_pmic_err_debug_driver = {
	.probe		= spmi_pmic_err_debug_probe,
	.driver		= {
		.name	= "spmi_pmic_err_debug",
		.of_match_table = spmi_pmic_err_debug_match_table,
	},
};
module_platform_driver(spmi_pmic_err_debug_driver);

MODULE_DESCRIPTION("QCOM SPMI error debug driver");
MODULE_LICENSE("GPL");
