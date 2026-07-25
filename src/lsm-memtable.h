/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LSM_MEMTABLE_H
#define _LSM_MEMTABLE_H

#include <linux/mutex.h>
#include <linux/rbtree.h>
#include <linux/spinlock.h>
#include <linux/types.h>

struct lsm_entry {
	struct rb_node node;
	sector_t logical_block;
	sector_t physical_sector;
	u64 sequence;
};

struct lsm_memtable {
	struct rb_root root;
	u64 next_sequence;
	unsigned int nr_entries;
	spinlock_t lock;
};

struct lsm_memtable *memtable_create(void);
void memtable_free(struct lsm_memtable *memtable);
int memtable_freeze_prepared(struct lsm_memtable **active,
			     struct lsm_memtable **immutable,
			     struct mutex *table_lock,
			     struct lsm_memtable *new_active);
int memtable_freeze(struct lsm_memtable **active,
		    struct lsm_memtable **immutable,
		    struct mutex *table_lock);
unsigned int memtable_size(struct lsm_memtable *memtable);
int memtable_lookup_active_immutable(
			struct lsm_memtable **active,
			struct lsm_memtable **immutable,
			struct mutex *table_lock,
			sector_t logical_block,
			sector_t *physical_sector);
int memtable_put_active(struct lsm_memtable **active,
			struct lsm_memtable **immutable,
			struct mutex *table_lock,
			unsigned int threshold,
			sector_t logical_block,
			sector_t physical_sector);
int memtable_init(struct lsm_memtable *memtable);
void memtable_destroy(struct lsm_memtable *memtable);
int memtable_lookup(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t *physical_sector, u64 *sequence);
int memtable_insert(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t physical_sector);
int memtable_update(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t physical_sector);
int memtable_put(struct lsm_memtable *memtable, sector_t logical_block,
		 sector_t physical_sector);

#endif
