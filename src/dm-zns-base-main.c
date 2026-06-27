// SPDX-License-Identifier: GPL-2.0
/*
 * dm-zns-base: Device Mapper target shell for ZNS translation engines.
 */

#include <linux/device-mapper.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "zns-engine.h"

#define DM_MSG_PREFIX "zns-base"

struct zns_base_c {
	struct dm_dev *dev;
	struct zns_engine engine;
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

	ret = dm_get_device(ti, argv[0], dm_table_get_mode(ti->table), &c->dev);
	if (ret) {
		ti->error = "failed to open underlying device";
		kfree(c);
		return ret;
	}

	ret = zns_engine_init(&c->engine, c->dev->bdev, ti->len, ti->len, ZNS_BASE_BLOCK_SECTORS);
	if (ret) {
		ti->error = "failed to initialize ZNS engine";
		dm_put_device(ti, c->dev);
		kfree(c);
		return ret;
	}

	ret = dm_set_target_max_io_len(ti, ZNS_BASE_BLOCK_SECTORS);
	if (ret) {
		ti->error = "failed to set target max io length";
		zns_engine_exit(&c->engine);
		dm_put_device(ti, c->dev);
		kfree(c);
		return ret;
	}

	ti->private = c;
	ti->num_flush_bios = 1;

	DMINFO("ctr: target attached on top of %s using %s engine", argv[0], zns_engine_name());
	return 0;
}

static void zns_base_dtr(struct dm_target *ti)
{
	struct zns_base_c *c = ti->private;

	zns_engine_exit(&c->engine);
	dm_put_device(ti, c->dev);
	kfree(c);
	DMINFO("dtr: target detached");
}

static int zns_base_map(struct dm_target *ti, struct bio *bio)
{
	struct zns_base_c *c = ti->private;

	return zns_engine_map(&c->engine, bio);
}

static struct target_type zns_base_target = {
	.name            = "zns-base",
	.version         = {0, 1, 0},
	.module          = THIS_MODULE,
	.ctr             = zns_base_ctr,
	.dtr             = zns_base_dtr,
	.map             = zns_base_map,
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

MODULE_DESCRIPTION("ZNS base dm target");
MODULE_AUTHOR("SPLAB");
MODULE_LICENSE("GPL");
