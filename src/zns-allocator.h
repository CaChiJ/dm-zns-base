/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ZNS_ALLOCATOR_H
#define _ZNS_ALLOCATOR_H

#include <linux/spinlock.h>
#include <linux/types.h>

#include "zns-zone.h"

enum zns_allocator_mode {
	ZNS_ALLOCATOR_LINEAR,
	ZNS_ALLOCATOR_ZONED,
};

struct zns_allocator {
	sector_t next_sector;
	sector_t physical_sectors;
	struct zns_zone *zones;
	unsigned int nr_zones;
	unsigned int active_zone;
	unsigned int reserve_zone;
	sector_t sectors_per_block;
	enum zns_allocator_mode mode;
	spinlock_t lock;
};

int zns_allocator_init(struct zns_allocator *allocator,
		       sector_t physical_sectors,
		       sector_t sectors_per_block);
int zns_allocator_init_zoned(struct zns_allocator *allocator,
			     const struct zns_zone *zones,
			     unsigned int nr_zones,
			     sector_t sectors_per_block);
void zns_allocator_exit(struct zns_allocator *allocator);
int zns_allocator_alloc(struct zns_allocator *allocator,
			sector_t *physical_sector);
/* Initialization only: select an empty data zone before starting I/O. */
int zns_allocator_set_reserve(struct zns_allocator *allocator, unsigned int zone);
/* Checks ordinary space, excluding the reserve; takes the allocator lock. */
bool zns_allocator_has_space(struct zns_allocator *allocator);
/*
 * GC-only operations below do not take the allocator lock. The caller must
 * serialize them with allocation and lower data I/O (the LSM ordered worker).
 * alloc_gc reserves one block in memory; it does not submit a device write.
 */
int zns_allocator_alloc_gc(struct zns_allocator *allocator, sector_t *physical_sector);
/*
 * Call only after all live blocks have moved and the device reset succeeded.
 * Updates memory only: the reset victim becomes the reserve, and the previous
 * reserve becomes ordinary space. This function never issues a device reset.
 */
int zns_allocator_set_reserve_after_reset(struct zns_allocator *allocator, unsigned int victim);
/* Caller must serialize allocation and lower writes across report and resync. */
int zns_allocator_resync(struct zns_allocator *allocator,
			 sector_t failed_sector, const struct zns_zone *reported);

#endif
