// SPDX-License-Identifier: GPL-2.0
/*
 * Simple physical append allocator.
 *
 * Supports the original linear allocation mode and zone-capacity-aware
 * allocation for callers that provide discovered zone metadata.
 */

#include <linux/blkzoned.h>
#include <linux/errno.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "zns-allocator.h"

static void zns_allocator_reset(struct zns_allocator *allocator)
{
	allocator->next_sector = 0;
	allocator->physical_sectors = 0;
	allocator->zones = NULL;
	allocator->nr_zones = 0;
	allocator->active_zone = 0;
	allocator->sectors_per_block = 0;
	allocator->mode = ZNS_ALLOCATOR_LINEAR;
}

int zns_allocator_init(struct zns_allocator *allocator,
		       sector_t physical_sectors,
		       sector_t sectors_per_block)
{
	if (!allocator || !sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	zns_allocator_reset(allocator);
	allocator->next_sector = 0;
	allocator->physical_sectors = physical_sectors;
	allocator->sectors_per_block = sectors_per_block;
	allocator->mode = ZNS_ALLOCATOR_LINEAR;
	spin_lock_init(&allocator->lock);

	return 0;
}

static bool zns_zone_is_writable(const struct zns_zone *zone)
{
	return zone->condition != BLK_ZONE_COND_FULL &&
	       zone->condition != BLK_ZONE_COND_READONLY &&
	       zone->condition != BLK_ZONE_COND_OFFLINE;
}

static bool zns_zone_metadata_valid(const struct zns_zone *zone)
{
	if (!zone->length || zone->capacity > zone->length)
		return false;
	if (zone->capacity > (sector_t)-1 - zone->start_sector)
		return false;
	if (zns_zone_is_writable(zone) &&
	    (zone->write_pointer < zone->start_sector ||
	     zone->write_pointer > zone->start_sector + zone->capacity))
		return false;

	return true;
}

int zns_allocator_init_zoned(struct zns_allocator *allocator,
			     const struct zns_zone *zones,
			     unsigned int nr_zones,
			     sector_t sectors_per_block)
{
	struct zns_zone *owned_zones;
	unsigned int i;

	if (!allocator || !zones || !nr_zones || !sectors_per_block)
		return -EINVAL;

	for (i = 0; i < nr_zones; i++)
		if (!zns_zone_metadata_valid(&zones[i]))
			return -EINVAL;

	owned_zones = kmalloc_array(nr_zones, sizeof(*owned_zones), GFP_KERNEL);
	if (!owned_zones)
		return -ENOMEM;
	memcpy(owned_zones, zones, nr_zones * sizeof(*owned_zones));

	zns_allocator_reset(allocator);
	allocator->zones = owned_zones;
	allocator->nr_zones = nr_zones;
	allocator->sectors_per_block = sectors_per_block;
	allocator->mode = ZNS_ALLOCATOR_ZONED;
	spin_lock_init(&allocator->lock);

	return 0;
}

void zns_allocator_exit(struct zns_allocator *allocator)
{
	if (!allocator)
		return;

	kfree(allocator->zones);
	zns_allocator_reset(allocator);
}

static int zns_allocator_alloc_zoned(struct zns_allocator *allocator,
				     sector_t *physical_sector)
{
	while (allocator->active_zone < allocator->nr_zones) {
		struct zns_zone *zone =
			&allocator->zones[allocator->active_zone];
		sector_t zone_end = zone->start_sector + zone->capacity;

		if (zns_zone_is_writable(zone) &&
		    zone->write_pointer <= zone_end &&
		    allocator->sectors_per_block <=
			    zone_end - zone->write_pointer) {
			*physical_sector = zone->write_pointer;
			zone->write_pointer += allocator->sectors_per_block;
			if (allocator->sectors_per_block >
			    zone_end - zone->write_pointer)
				allocator->active_zone++;
			return 0;
		}

		allocator->active_zone++;
	}

	return -ENOSPC;
}

int zns_allocator_alloc(struct zns_allocator *allocator,
			sector_t *physical_sector)
{
	int ret = 0;

	if (!allocator || !physical_sector)
		return -EINVAL;

	spin_lock(&allocator->lock);
	if (allocator->mode == ZNS_ALLOCATOR_ZONED) {
		ret = zns_allocator_alloc_zoned(allocator, physical_sector);
	} else if (allocator->next_sector > allocator->physical_sectors ||
		   allocator->sectors_per_block >
		   allocator->physical_sectors - allocator->next_sector) {
		ret = -ENOSPC;
	} else {
		*physical_sector = allocator->next_sector;
		allocator->next_sector += allocator->sectors_per_block;
	}
	spin_unlock(&allocator->lock);

	return ret;
}

int zns_allocator_rollback(struct zns_allocator *allocator,
			   sector_t physical_sector)
{
	int ret = -EBUSY;

	if (!allocator)
		return -EINVAL;

	spin_lock(&allocator->lock);
	if (allocator->mode == ZNS_ALLOCATOR_LINEAR) {
		if (allocator->next_sector ==
		    physical_sector + allocator->sectors_per_block) {
			allocator->next_sector = physical_sector;
			ret = 0;
		}
	} else {
		unsigned int i;

		for (i = 0; i < allocator->nr_zones; i++) {
			struct zns_zone *zone = &allocator->zones[i];
			sector_t zone_end = zone->start_sector + zone->capacity;

			if (physical_sector < zone->start_sector ||
			    physical_sector >= zone_end)
				continue;
			if (zone->write_pointer !=
			    physical_sector + allocator->sectors_per_block)
				break;

			zone->write_pointer = physical_sector;
			if (allocator->active_zone > i)
				allocator->active_zone = i;
			ret = 0;
			break;
		}
	}
	spin_unlock(&allocator->lock);

	return ret;
}
