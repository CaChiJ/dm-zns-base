// SPDX-License-Identifier: GPL-2.0
/*
 * dm-zns-base: M0 scaffold for the capstone project.
 *
 * Registers a zoned-aware pass-through DM target on top of a host-managed
 * zoned device. The random-to-sequential translation that the project is
 * actually about is left out on purpose — that's the student's work.
 * See docs/07-milestones.md.
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/bio.h>
#include <linux/device-mapper.h>

#define DM_MSG_PREFIX "zns-base"

struct zns_base_c {
	struct dm_dev *dev;
};

static int zns_base_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct zns_base_c *c;
	int ret;

	if (argc != 1) {
		ti->error = "expected one argument: underlying device";
		return -EINVAL;
	}

	c = kzalloc(sizeof(*c), GFP_KERNEL);
	if (!c) {
		ti->error = "out of memory";
		return -ENOMEM;
	}

	ret = dm_get_device(ti, argv[0], dm_table_get_mode(ti->table),
			    &c->dev);
	if (ret) {
		ti->error = "failed to open underlying device";
		kfree(c);
		return ret;
	}

	ti->private = c;
	ti->num_flush_bios = 1;
	ti->num_discard_bios = 1;

	DMINFO("ctr: target attached on top of '%s'", argv[0]);
	return 0;
}

static void zns_base_dtr(struct dm_target *ti)
{
	struct zns_base_c *c = ti->private;

	dm_put_device(ti, c->dev);
	kfree(c);
	DMINFO("dtr: target detached");
}

static int zns_base_map(struct dm_target *ti, struct bio *bio)
{
	struct zns_base_c *c = ti->private;

	/* Student work goes here: translate random writes into sequential ones. */
	bio_set_dev(bio, c->dev->bdev);
	return DM_MAPIO_REMAPPED;
}

/* 1:1 mapping, so ti->begin is passed straight through. A non-identity
 * mapping would need to translate args->next_sector. */
static int zns_base_report_zones(struct dm_target *ti,
				 struct dm_report_zones_args *args,
				 unsigned int nr_zones)
{
	struct zns_base_c *c = ti->private;

	return dm_report_zones(c->dev->bdev, ti->begin,
			       args->next_sector, args, nr_zones);
}

/* DM_TARGET_ZONED_HM is just a capability flag. Without this callback the
 * underlying device's chunk_sectors and zoned attributes never propagate up
 * to the DM queue, and blkzone fails with "unable to determine zone size". */
static int zns_base_iterate_devices(struct dm_target *ti,
				    iterate_devices_callout_fn fn, void *data)
{
	struct zns_base_c *c = ti->private;

	return fn(ti, c->dev, 0, ti->len, data);
}

static struct target_type zns_base_target = {
	.name            = "zns-base",
	.version         = {0, 1, 0},
	.features        = DM_TARGET_ZONED_HM,
	.module          = THIS_MODULE,
	.ctr             = zns_base_ctr,
	.dtr             = zns_base_dtr,
	.map             = zns_base_map,
	.report_zones    = zns_base_report_zones,
	.iterate_devices = zns_base_iterate_devices,
};

static int __init zns_base_init(void)
{
	int ret = dm_register_target(&zns_base_target);

	if (ret < 0)
		DMERR("target registration failed: %d", ret);
	else
		DMINFO("target registered");
	return ret;
}

static void __exit zns_base_exit(void)
{
	dm_unregister_target(&zns_base_target);
	DMINFO("target unregistered");
}

module_init(zns_base_init);
module_exit(zns_base_exit);

MODULE_DESCRIPTION("ZNS base dm target (zoned-aware pass-through scaffold)");
MODULE_AUTHOR("SPLAB");
MODULE_LICENSE("GPL");
