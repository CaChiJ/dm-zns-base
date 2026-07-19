// SPDX-License-Identifier: GPL-2.0
/*
 * Simple physical append allocator.
 *
 * This first version intentionally knows nothing about zones. It allocates
 * fixed-size physical blocks linearly from sector zero.
 */

#include <linux/errno.h>

#include "zns-allocator.h"

int zns_allocator_init(struct zns_allocator *allocator,
		       sector_t physical_sectors,
		       sector_t sectors_per_block)
{
	if (!allocator || !sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	allocator->next_sector = 0;
	allocator->physical_sectors = physical_sectors;
	allocator->sectors_per_block = sectors_per_block;
	spin_lock_init(&allocator->lock);

	return 0;
}

void zns_allocator_exit(struct zns_allocator *allocator)
{
	/* The allocator currently owns no dynamic resources. */
	(void)allocator;
}

int zns_allocator_alloc(struct zns_allocator *allocator,
			sector_t *physical_sector)
{
	int ret = 0;

	if (!allocator || !physical_sector)
		return -EINVAL;

	spin_lock(&allocator->lock);
	if (allocator->next_sector + allocator->sectors_per_block >
	    allocator->physical_sectors) {
		ret = -ENOSPC;
	} else {
		*physical_sector = allocator->next_sector;
		allocator->next_sector += allocator->sectors_per_block;
	}
	spin_unlock(&allocator->lock);

	return ret;
}
