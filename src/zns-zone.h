/* SPDX-License-Identifier: GPL-2.0 */
#ifndef DM_ZNS_BASE_ZONE_H
#define DM_ZNS_BASE_ZONE_H

#include <linux/blk_types.h>
#include <linux/types.h>

struct block_device;

struct zns_zone {
	u32 id;
	sector_t start_sector;
	sector_t length;
	sector_t capacity;
	sector_t write_pointer;
	bool active;
};

struct zns_zone_table {
	struct zns_zone *zones;
	unsigned int nr_zones;
};

int zns_zone_table_init(struct zns_zone_table *table,
			struct block_device *bdev);
void zns_zone_table_destroy(struct zns_zone_table *table);

#endif /* DM_ZNS_BASE_ZONE_H */
