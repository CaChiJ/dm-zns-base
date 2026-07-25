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

static int memtable_freeze_prepared_locked(
		struct lsm_memtable **active,
		struct lsm_memtable **immutable,
		struct lsm_memtable *new_active)
{
	if (!new_active)
		return -ENOMEM;
	if (!*active) {
		return -EINVAL;
	}
	if (*immutable)
		return -EBUSY;

	*immutable = *active;
	*active = new_active;
	return 0;
}

int memtable_freeze_prepared(struct lsm_memtable **active,
			     struct lsm_memtable **immutable,
			     struct mutex *table_lock,
			     struct lsm_memtable *new_active)
{
	int ret;

	if (!active || !immutable || !table_lock)
		return -EINVAL;

	mutex_lock(table_lock);
	ret = memtable_freeze_prepared_locked(active, immutable, new_active);
	mutex_unlock(table_lock);

	return ret;
}

int memtable_freeze(struct lsm_memtable **active,
		    struct lsm_memtable **immutable,
		    struct mutex *table_lock)
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

unsigned int memtable_size(struct lsm_memtable *memtable)
{
	unsigned int nr_entries;

	if (!memtable)
		return 0;

	spin_lock(&memtable->lock);
	nr_entries = memtable->nr_entries;
	spin_unlock(&memtable->lock);

	return nr_entries;
}

int memtable_lookup_active_immutable(
			struct lsm_memtable **active,
			struct lsm_memtable **immutable,
			struct mutex *table_lock,
			sector_t logical_block,
			sector_t *physical_sector)
{
	int ret;

	if (!active || !immutable || !table_lock || !physical_sector)
		return -EINVAL;

	mutex_lock(table_lock);
	if (!*active) {
		ret = -EINVAL;
		goto unlock;
	}

	ret = memtable_lookup(*active, logical_block, physical_sector, NULL);
	if (ret == -ENODATA && *immutable)
		ret = memtable_lookup(*immutable, logical_block,
				      physical_sector, NULL);

unlock:
	mutex_unlock(table_lock);
	return ret;
}

int memtable_put_active(struct lsm_memtable **active,
			struct lsm_memtable **immutable,
			struct mutex *table_lock,
			unsigned int threshold,
			sector_t logical_block,
			sector_t physical_sector)
{
	struct lsm_memtable *new_active;
	int ret;

	if (!active || !immutable || !table_lock || !threshold)
		return -EINVAL;

	mutex_lock(table_lock);
	if (!*active) {
		ret = -EINVAL;
		goto unlock;
	}

	ret = memtable_put(*active, logical_block, physical_sector);
	if (ret)
		goto unlock;

	if (memtable_size(*active) < threshold || *immutable)
		goto unlock;

	new_active = memtable_create();
	if (!new_active)
		goto unlock;

	ret = memtable_freeze_prepared_locked(active, immutable, new_active);
	if (ret) {
		memtable_free(new_active);
		/*
		 * The mapping was already stored successfully. Freeze failure
		 * must not turn the completed write into an I/O error.
		 */
		ret = 0;
	}

unlock:
	mutex_unlock(table_lock);
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
