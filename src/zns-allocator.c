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
	allocator->reserve_zone = UINT_MAX;
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

int zns_allocator_resync(struct zns_allocator *allocator,
			 sector_t failed_sector, const struct zns_zone *reported)
{
	struct zns_zone *zone;
	sector_t end, block = allocator->sectors_per_block;
	unsigned int i;
	int ret = -EIO;

	spin_lock(&allocator->lock);
	if (allocator->mode != ZNS_ALLOCATOR_ZONED || !block)
		goto out;
	for (i = 0; i < allocator->nr_zones; i++)
		if (allocator->zones[i].start_sector == reported->start_sector)
			break;
	if (i == allocator->nr_zones)
		goto out;
	zone = &allocator->zones[i];
	if (reported->length != zone->length ||
	    reported->capacity != zone->capacity ||
	    !zns_zone_metadata_valid(reported))
		goto out;
	end = zone->start_sector + zone->capacity;
	if (failed_sector < zone->start_sector || failed_sector > end ||
	    block > end - failed_sector || failed_sector % block ||
	    zone->write_pointer != failed_sector + block)
		goto out;
	/* Only an unchanged WP or consumption of this one block is recoverable. */
	if (reported->write_pointer != failed_sector &&
	    reported->write_pointer != failed_sector + block)
		goto out;
	switch (reported->condition) {
	case BLK_ZONE_COND_EMPTY:
		if (reported->write_pointer != zone->start_sector)
			goto out;
		break;
	case BLK_ZONE_COND_IMP_OPEN:
	case BLK_ZONE_COND_EXP_OPEN:
	case BLK_ZONE_COND_CLOSED:
		break;
	case BLK_ZONE_COND_FULL:
		if (reported->write_pointer != end)
			goto out;
		break;
	default:
		goto out;
	}
	zone->write_pointer = reported->write_pointer;
	zone->condition = reported->condition;
	zone->active = reported->active;
	/* Allocation may already have advanced past the failed zone's last slot. */
	allocator->active_zone = i;
	if (zone->condition == BLK_ZONE_COND_FULL ||
	    block > end - zone->write_pointer)
		allocator->active_zone++;
	ret = 0;
out:
	spin_unlock(&allocator->lock);
	return ret;
}

static int zns_allocator_alloc_zoned(struct zns_allocator *allocator,
				     sector_t *physical_sector)
{
	unsigned int checked;

	if (allocator->active_zone >= allocator->nr_zones)
		allocator->active_zone = 0;
	for (checked = 0; checked < allocator->nr_zones; checked++) {
		struct zns_zone *zone =
			&allocator->zones[allocator->active_zone];
		sector_t zone_end = zone->start_sector + zone->capacity;

		if (allocator->active_zone != allocator->reserve_zone &&
		    zns_zone_is_writable(zone) &&
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

		allocator->active_zone =
			(allocator->active_zone + 1) % allocator->nr_zones;
	}

	return -ENOSPC;
}

int zns_allocator_set_reserve(struct zns_allocator *allocator,
			      unsigned int zone)
{
	struct zns_zone *z;

	if (!allocator || allocator->mode != ZNS_ALLOCATOR_ZONED ||
	    zone >= allocator->nr_zones)
		return -EINVAL;
	z = &allocator->zones[zone];
	if (!zns_zone_is_writable(z) ||
	    z->capacity < allocator->sectors_per_block ||
	    z->write_pointer != z->start_sector)
		return -ENOSPC;
	allocator->reserve_zone = zone;
	return 0;
}

bool zns_allocator_has_space(struct zns_allocator *allocator)
{
	unsigned int i;
	bool found = false;

	spin_lock(&allocator->lock);
	for (i = 0; i < allocator->nr_zones; i++) {
		const struct zns_zone *z = &allocator->zones[i];
		sector_t end = z->start_sector + z->capacity;

		if (i != allocator->reserve_zone && zns_zone_is_writable(z) &&
		    z->write_pointer <= end &&
		    allocator->sectors_per_block <= end - z->write_pointer) {
			found = true;
			break;
		}
	}
	spin_unlock(&allocator->lock);
	return found;
}

int zns_allocator_alloc_gc(struct zns_allocator *allocator,
			   sector_t *physical_sector)
{
	struct zns_zone *z;
	sector_t end;

	if (!allocator || !physical_sector ||
	    allocator->reserve_zone >= allocator->nr_zones)
		return -EINVAL;
	z = &allocator->zones[allocator->reserve_zone];
	end = z->start_sector + z->capacity;
	if (!zns_zone_is_writable(z) || z->write_pointer > end ||
	    allocator->sectors_per_block > end - z->write_pointer)
		return -ENOSPC;
	*physical_sector = z->write_pointer;
	z->write_pointer += allocator->sectors_per_block;
	return 0;
}

int zns_allocator_rotate_reserve(struct zns_allocator *allocator,
				 unsigned int victim)
{
	struct zns_zone *z;

	if (!allocator || victim >= allocator->nr_zones ||
	    victim == allocator->reserve_zone)
		return -EINVAL;
	z = &allocator->zones[victim];
	z->write_pointer = z->start_sector;
	z->condition = BLK_ZONE_COND_EMPTY;
	allocator->reserve_zone = victim;
	return 0;
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
