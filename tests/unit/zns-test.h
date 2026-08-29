/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Case table for the standalone dm-zns-base kernel test modules.
 *
 * Every case runs even when an earlier one fails, and each result is printed
 * on its own line. tests/support/lib/common.sh parses those lines back into the
 * per-case PASS/FAIL output the shell suites produce, so a kernel unit test
 * and a shell integration test read the same way.
 */
#ifndef ZNS_TEST_H
#define ZNS_TEST_H

#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/printk.h>

struct zns_test_case {
	const char *name;
	const char *description;
	int (*run)(void);
};

#define ZNS_TEST_CASE(fn, desc) { #fn, desc, fn }

/*
 * Print one line per case, then a suite line. The description comes last on
 * the line because it is the only field that contains spaces.
 */
static inline int zns_test_run(const char *suite,
			       const struct zns_test_case *cases,
			       unsigned int nr_cases)
{
	unsigned int failures = 0;
	unsigned int i;

	for (i = 0; i < nr_cases; i++) {
		int ret = cases[i].run();

		if (ret) {
			failures++;
			pr_err("zns-test: suite=%s case=%s result=FAIL ret=%d desc=%s\n",
			       suite, cases[i].name, ret, cases[i].description);
		} else {
			pr_info("zns-test: suite=%s case=%s result=PASS desc=%s\n",
				suite, cases[i].name, cases[i].description);
		}
	}

	if (failures) {
		pr_err("zns-test: suite=%s result=FAIL failures=%u of %u\n",
		       suite, failures, nr_cases);
		return -EINVAL;
	}

	pr_info("zns-test: suite=%s result=PASS cases=%u\n", suite, nr_cases);
	return 0;
}

#endif /* ZNS_TEST_H */
