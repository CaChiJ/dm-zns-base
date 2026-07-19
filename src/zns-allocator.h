/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ZNS_ALLOCATOR_H
#define _ZNS_ALLOCATOR_H

#include <linux/spinlock.h>
#include <linux/types.h>

struct zns_allocator {
	sector_t next_sector;
	sector_t physical_sectors;
	sector_t sectors_per_block;
	spinlock_t lock;
};

int zns_allocator_init(struct zns_allocator *allocator,
		       sector_t physical_sectors,
		       sector_t sectors_per_block);
void zns_allocator_exit(struct zns_allocator *allocator);
int zns_allocator_alloc(struct zns_allocator *allocator,
			sector_t *physical_sector);

#endif
