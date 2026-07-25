// SPDX-License-Identifier: GPL-2.0
/* In-memory logical-to-physical mapping backed by the kernel RB-tree. */

#include <linux/errno.h>
#include <linux/slab.h>

#include "lsm-memtable.h"

static struct lsm_entry *memtable_find(struct lsm_memtable *memtable,
				       sector_t logical_block)
{
	struct rb_node *node = memtable->root.rb_node;

	while (node) {
		struct lsm_entry *entry;

		entry = rb_entry(node, struct lsm_entry, node);
		if (logical_block < entry->logical_block)
			node = node->rb_left;
		else if (logical_block > entry->logical_block)
			node = node->rb_right;
		else
			return entry;
	}

	return NULL;
}

struct lsm_memtable *memtable_create(void)
{
	struct lsm_memtable *memtable;
	int ret;

	memtable = kzalloc(sizeof(*memtable), GFP_KERNEL);
	if (!memtable)
		return NULL;

	ret = memtable_init(memtable);
	if (ret) {
		kfree(memtable);
		return NULL;
	}

	return memtable;
}

void memtable_free(struct lsm_memtable *memtable)
{
	if (!memtable)
		return;

	memtable_destroy(memtable);
	kfree(memtable);
}

int memtable_freeze_prepared(struct lsm_memtable **active,
			     struct lsm_memtable **immutable,
			     spinlock_t *table_lock,
			     struct lsm_memtable *new_active)
{
	int ret = 0;

	if (!active || !immutable || !table_lock)
		return -EINVAL;
	if (!new_active)
		return -ENOMEM;

	spin_lock(table_lock);
	if (!*active) {
		ret = -EINVAL;
	} else if (*immutable) {
		ret = -EBUSY;
	} else {
		*immutable = *active;
		*active = new_active;
	}
	spin_unlock(table_lock);

	return ret;
}

int memtable_freeze(struct lsm_memtable **active,
		    struct lsm_memtable **immutable,
		    spinlock_t *table_lock)
{
	struct lsm_memtable *new_active;
	int ret;

	if (!active || !immutable || !table_lock)
		return -EINVAL;

	new_active = memtable_create();
	if (!new_active)
		return -ENOMEM;

	ret = memtable_freeze_prepared(active, immutable, table_lock,
				       new_active);
	if (ret)
		memtable_free(new_active);

	return ret;
}

int memtable_init(struct lsm_memtable *memtable)
{
	if (!memtable)
		return -EINVAL;

	memtable->root = RB_ROOT;
	memtable->next_sequence = 1;
	memtable->nr_entries = 0;
	spin_lock_init(&memtable->lock);

	return 0;
}

void memtable_destroy(struct lsm_memtable *memtable)
{
	struct rb_node *node;

	if (!memtable)
		return;

	spin_lock(&memtable->lock);
	while ((node = rb_first(&memtable->root))) {
		struct lsm_entry *entry;

		entry = rb_entry(node, struct lsm_entry, node);
		rb_erase(node, &memtable->root);
		kfree(entry);
	}
	memtable->nr_entries = 0;
	spin_unlock(&memtable->lock);
}

int memtable_lookup(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t *physical_sector, u64 *sequence)
{
	struct lsm_entry *entry;
	int ret = 0;

	if (!memtable || !physical_sector)
		return -EINVAL;

	spin_lock(&memtable->lock);
	entry = memtable_find(memtable, logical_block);
	if (!entry) {
		ret = -ENODATA;
	} else {
		*physical_sector = entry->physical_sector;
		if (sequence)
			*sequence = entry->sequence;
	}
	spin_unlock(&memtable->lock);

	return ret;
}

int memtable_insert(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t physical_sector)
{
	struct rb_node **link;
	struct rb_node *parent = NULL;
	struct lsm_entry *new_entry;
	int ret = 0;

	if (!memtable)
		return -EINVAL;

	new_entry = kmalloc(sizeof(*new_entry), GFP_KERNEL);
	if (!new_entry)
		return -ENOMEM;

	new_entry->logical_block = logical_block;
	new_entry->physical_sector = physical_sector;

	spin_lock(&memtable->lock);
	link = &memtable->root.rb_node;
	while (*link) {
		struct lsm_entry *entry;

		parent = *link;
		entry = rb_entry(parent, struct lsm_entry, node);
		if (logical_block < entry->logical_block)
			link = &parent->rb_left;
		else if (logical_block > entry->logical_block)
			link = &parent->rb_right;
		else {
			ret = -EEXIST;
			goto unlock;
		}
	}

	new_entry->sequence = memtable->next_sequence++;
	rb_link_node(&new_entry->node, parent, link);
	rb_insert_color(&new_entry->node, &memtable->root);
	memtable->nr_entries++;

unlock:
	spin_unlock(&memtable->lock);
	if (ret)
		kfree(new_entry);

	return ret;
}

int memtable_update(struct lsm_memtable *memtable, sector_t logical_block,
		    sector_t physical_sector)
{
	struct lsm_entry *entry;
	int ret = 0;

	if (!memtable)
		return -EINVAL;

	spin_lock(&memtable->lock);
	entry = memtable_find(memtable, logical_block);
	if (!entry) {
		ret = -ENODATA;
	} else {
		entry->physical_sector = physical_sector;
		entry->sequence = memtable->next_sequence++;
	}
	spin_unlock(&memtable->lock);

	return ret;
}

int memtable_put(struct lsm_memtable *memtable, sector_t logical_block,
		 sector_t physical_sector)
{
	struct rb_node **link;
	struct rb_node *parent = NULL;
	struct lsm_entry *new_entry;
	bool inserted = false;

	if (!memtable)
		return -EINVAL;

	new_entry = kmalloc(sizeof(*new_entry), GFP_KERNEL);
	if (!new_entry)
		return -ENOMEM;

	new_entry->logical_block = logical_block;
	new_entry->physical_sector = physical_sector;

	spin_lock(&memtable->lock);
	link = &memtable->root.rb_node;
	while (*link) {
		struct lsm_entry *entry;

		parent = *link;
		entry = rb_entry(parent, struct lsm_entry, node);
		if (logical_block < entry->logical_block) {
			link = &parent->rb_left;
		} else if (logical_block > entry->logical_block) {
			link = &parent->rb_right;
		} else {
			entry->physical_sector = physical_sector;
			entry->sequence = memtable->next_sequence++;
			goto unlock;
		}
	}

	new_entry->sequence = memtable->next_sequence++;
	rb_link_node(&new_entry->node, parent, link);
	rb_insert_color(&new_entry->node, &memtable->root);
	memtable->nr_entries++;
	inserted = true;

unlock:
	spin_unlock(&memtable->lock);
	if (!inserted)
		kfree(new_entry);

	return 0;
}
