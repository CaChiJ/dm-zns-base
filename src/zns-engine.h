/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ZNS_ENGINE_H
#define _ZNS_ENGINE_H

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/types.h>

#define ZNS_BASE_BLOCK_SECTORS 8

struct zns_engine {
	void *private;
};

/* Engine별 private 상태를 초기화하고 0 또는 음수 errno를 반환한다. */
int zns_engine_init(struct zns_engine *engine, struct block_device *lower_bdev,
		    sector_t logical_sectors, sector_t physical_sectors,
		    sector_t sectors_per_block);

/* zns_engine_init()에서 만든 private 상태와 진행 중인 비동기 작업을 정리한다. */
void zns_engine_exit(struct zns_engine *engine);

/* DM .map()에서 받은 bio를 remap, 직접 완료, 또는 kill 중 하나로 처리한다. */
int zns_engine_map(struct zns_engine *engine, struct bio *bio);

/* 현재 빌드에 링크된 engine 이름을 정적 문자열로 반환한다. */
const char *zns_engine_name(void);

#endif
