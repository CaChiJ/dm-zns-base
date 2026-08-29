#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define BLOCK_SIZE 4096U
#define MANIFEST_VERSION 1U

static const unsigned char manifest_magic[8] = {
	'Z', 'N', 'S', 'V', 'E', 'R', '1', '\0'
};

struct manifest_header {
	unsigned char magic[8];
	uint32_t version;
	uint32_t block_size;
	uint64_t blocks;
};

struct manifest {
	uint64_t blocks;
	uint64_t *versions;
};

static void usage(const char *program)
{
	fprintf(stderr,
		"usage:\n"
		"  %s init DEVICE MANIFEST BLOCKS\n"
		"  %s overwrite DEVICE MANIFEST OPERATIONS SEED\n"
		"  %s verify DEVICE MANIFEST\n",
		program, program, program);
}

static int parse_u64(const char *text, uint64_t *value)
{
	char *end;
	unsigned long long parsed;

	errno = 0;
	parsed = strtoull(text, &end, 0);
	if (errno || !text[0] || *end)
		return -1;
	*value = (uint64_t)parsed;
	return 0;
}

static uint64_t splitmix64(uint64_t *state)
{
	uint64_t value;

	*state += UINT64_C(0x9e3779b97f4a7c15);
	value = *state;
	value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
	value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
	return value ^ (value >> 31);
}

static void make_block(void *buffer, uint64_t logical_block, uint64_t version)
{
	uint64_t *words = buffer;
	uint64_t state = logical_block ^
		(version * UINT64_C(0xd6e8feb86659fd93));
	size_t i;

	for (i = 0; i < BLOCK_SIZE / sizeof(*words); i++)
		words[i] = splitmix64(&state);

	words[0] = UINT64_C(0x5a4e53564552494f); /* "ZNSVERIO" */
	words[1] = logical_block;
	words[2] = version;
}

static int full_pwrite(int fd, const void *buffer, size_t length, off_t offset)
{
	const unsigned char *cursor = buffer;

	while (length) {
		ssize_t written = pwrite(fd, cursor, length, offset);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (!written) {
			errno = EIO;
			return -1;
		}
		cursor += written;
		length -= (size_t)written;
		offset += written;
	}
	return 0;
}

static int full_pread(int fd, void *buffer, size_t length, off_t offset)
{
	unsigned char *cursor = buffer;

	while (length) {
		ssize_t received = pread(fd, cursor, length, offset);

		if (received < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (!received) {
			errno = EIO;
			return -1;
		}
		cursor += received;
		length -= (size_t)received;
		offset += received;
	}
	return 0;
}

static void manifest_free(struct manifest *manifest)
{
	free(manifest->versions);
	manifest->versions = NULL;
	manifest->blocks = 0;
}

static int manifest_allocate(struct manifest *manifest, uint64_t blocks)
{
	if (!blocks || blocks > SIZE_MAX / sizeof(*manifest->versions)) {
		errno = EOVERFLOW;
		return -1;
	}

	manifest->versions = calloc((size_t)blocks,
				    sizeof(*manifest->versions));
	if (!manifest->versions)
		return -1;
	manifest->blocks = blocks;
	return 0;
}

static int manifest_save(const char *path, const struct manifest *manifest)
{
	struct manifest_header header = {
		.version = MANIFEST_VERSION,
		.block_size = BLOCK_SIZE,
		.blocks = manifest->blocks,
	};
	size_t path_length = strlen(path);
	char *temporary;
	int fd = -1;
	int ret = -1;

	memcpy(header.magic, manifest_magic, sizeof(header.magic));
	temporary = malloc(path_length + 32);
	if (!temporary)
		return -1;
	snprintf(temporary, path_length + 32, "%s.tmp.%ld", path, (long)getpid());

	fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	if (fd < 0)
		goto out;
	if (full_pwrite(fd, &header, sizeof(header), 0) ||
	    full_pwrite(fd, manifest->versions,
			manifest->blocks * sizeof(*manifest->versions),
			(off_t)sizeof(header)) ||
	    fsync(fd))
		goto out;
	if (close(fd)) {
		fd = -1;
		goto out;
	}
	fd = -1;
	if (rename(temporary, path))
		goto out;
	ret = 0;

out:
	if (fd >= 0)
		close(fd);
	if (ret)
		unlink(temporary);
	free(temporary);
	return ret;
}

static int manifest_load(const char *path, struct manifest *manifest)
{
	struct manifest_header header;
	struct stat statbuf;
	off_t expected_size;
	int fd;
	int ret = -1;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	if (fstat(fd, &statbuf) ||
	    full_pread(fd, &header, sizeof(header), 0))
		goto out;
	if (memcmp(header.magic, manifest_magic, sizeof(header.magic)) ||
	    header.version != MANIFEST_VERSION ||
	    header.block_size != BLOCK_SIZE || !header.blocks) {
		errno = EINVAL;
		goto out;
	}
	if (header.blocks > (uint64_t)(INT64_MAX - (off_t)sizeof(header)) /
				    sizeof(*manifest->versions)) {
		errno = EOVERFLOW;
		goto out;
	}
	expected_size = (off_t)sizeof(header) +
		(off_t)(header.blocks * sizeof(*manifest->versions));
	if (statbuf.st_size != expected_size) {
		errno = EINVAL;
		goto out;
	}
	if (manifest_allocate(manifest, header.blocks))
		goto out;
	if (full_pread(fd, manifest->versions,
		       manifest->blocks * sizeof(*manifest->versions),
		       (off_t)sizeof(header))) {
		manifest_free(manifest);
		goto out;
	}
	ret = 0;

out:
	close(fd);
	return ret;
}

static int open_device(const char *path, int flags)
{
	return open(path, flags | O_DIRECT | O_CLOEXEC);
}

static int allocate_block(void **buffer)
{
	int ret = posix_memalign(buffer, BLOCK_SIZE, BLOCK_SIZE);

	if (ret)
		errno = ret;
	return ret ? -1 : 0;
}

static int command_init(const char *device, const char *manifest_path,
			uint64_t blocks)
{
	struct manifest manifest = { 0 };
	void *buffer = NULL;
	uint64_t block;
	int fd = -1;
	int ret = -1;

	if (blocks > (uint64_t)INT64_MAX / BLOCK_SIZE) {
		errno = EOVERFLOW;
		goto out;
	}
	if (manifest_allocate(&manifest, blocks) || allocate_block(&buffer))
		goto out;
	fd = open_device(device, O_RDWR);
	if (fd < 0)
		goto out;

	for (block = 0; block < blocks; block++) {
		manifest.versions[block] = 1;
		make_block(buffer, block, 1);
		if (full_pwrite(fd, buffer, BLOCK_SIZE,
				(off_t)(block * BLOCK_SIZE)))
			goto out;
	}
	if (fdatasync(fd) || manifest_save(manifest_path, &manifest))
		goto out;
	ret = 0;

out:
	if (ret)
		fprintf(stderr, "versioned-io init: %s\n", strerror(errno));
	if (fd >= 0)
		close(fd);
	free(buffer);
	manifest_free(&manifest);
	return ret;
}

static int command_overwrite(const char *device, const char *manifest_path,
			     uint64_t operations, uint64_t seed)
{
	struct manifest manifest = { 0 };
	void *buffer = NULL;
	uint64_t operation;
	int fd = -1;
	int ret = -1;

	if (!operations) {
		errno = EINVAL;
		goto out;
	}
	if (manifest_load(manifest_path, &manifest) || allocate_block(&buffer))
		goto out;
	fd = open_device(device, O_RDWR);
	if (fd < 0)
		goto out;

	if (!seed)
		seed = UINT64_C(0x6a09e667f3bcc909);
	for (operation = 0; operation < operations; operation++) {
		uint64_t logical_block = splitmix64(&seed) % manifest.blocks;
		uint64_t version = ++manifest.versions[logical_block];

		make_block(buffer, logical_block, version);
		if (full_pwrite(fd, buffer, BLOCK_SIZE,
				(off_t)(logical_block * BLOCK_SIZE)))
			goto out;
	}
	if (fdatasync(fd) || manifest_save(manifest_path, &manifest))
		goto out;
	ret = 0;

out:
	if (ret)
		fprintf(stderr, "versioned-io overwrite: %s\n", strerror(errno));
	if (fd >= 0)
		close(fd);
	free(buffer);
	manifest_free(&manifest);
	return ret;
}

static int command_verify(const char *device, const char *manifest_path)
{
	struct manifest manifest = { 0 };
	void *actual = NULL;
	void *expected = NULL;
	uint64_t block;
	int fd = -1;
	int ret = -1;

	if (manifest_load(manifest_path, &manifest) || allocate_block(&actual) ||
	    allocate_block(&expected))
		goto out;
	fd = open_device(device, O_RDONLY);
	if (fd < 0)
		goto out;

	for (block = 0; block < manifest.blocks; block++) {
		if (full_pread(fd, actual, BLOCK_SIZE,
			       (off_t)(block * BLOCK_SIZE)))
			goto out;
		make_block(expected, block, manifest.versions[block]);
		if (memcmp(actual, expected, BLOCK_SIZE)) {
			fprintf(stderr,
				"versioned-io verify: block=%" PRIu64
				" expected_version=%" PRIu64 " differs\n",
				block, manifest.versions[block]);
			errno = EILSEQ;
			goto out;
		}
	}
	ret = 0;

out:
	if (ret && errno != EILSEQ)
		fprintf(stderr, "versioned-io verify: %s\n", strerror(errno));
	if (fd >= 0)
		close(fd);
	free(actual);
	free(expected);
	manifest_free(&manifest);
	return ret;
}

int main(int argc, char **argv)
{
	uint64_t first;
	uint64_t second;

	if (argc == 5 && !strcmp(argv[1], "init")) {
		if (parse_u64(argv[4], &first) || !first)
			goto invalid;
		return command_init(argv[2], argv[3], first) ? EXIT_FAILURE : EXIT_SUCCESS;
	}
	if (argc == 6 && !strcmp(argv[1], "overwrite")) {
		if (parse_u64(argv[4], &first) || !first ||
		    parse_u64(argv[5], &second))
			goto invalid;
		return command_overwrite(argv[2], argv[3], first, second) ?
			EXIT_FAILURE : EXIT_SUCCESS;
	}
	if (argc == 4 && !strcmp(argv[1], "verify"))
		return command_verify(argv[2], argv[3]) ? EXIT_FAILURE : EXIT_SUCCESS;

invalid:
	usage(argv[0]);
	return EXIT_FAILURE;
}
