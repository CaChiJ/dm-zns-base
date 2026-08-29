#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MAP_BLOCK_BYTES 4096U
#define STREAM_CHUNK_BYTES (1024U * 1024U)
#define BASELINE_SEED UINT64_C(0x424153454c494e45)

static void usage(const char *program)
{
	fprintf(stderr,
		"usage:\n"
		"  %s write DEVICE OFFSET LENGTH REQUEST SEED\n"
		"  %s update DEVICE OFFSET LENGTH REQUEST SEED\n"
		"  %s randwrite DEVICE OFFSET RANGE REQUEST TOTAL SEED\n",
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

static uint64_t mix64(uint64_t value)
{
	value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
	value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
	return value ^ (value >> 31);
}

static uint64_t next_random(uint64_t *state)
{
	*state += UINT64_C(0x9e3779b97f4a7c15);
	return mix64(*state);
}

static void fill_pattern(unsigned char *buffer, size_t length,
			 uint64_t absolute_offset, uint64_t seed)
{
	size_t cursor = 0;

	while (cursor < length) {
		uint64_t position = absolute_offset + cursor;
		uint64_t word = mix64(seed ^ (position / sizeof(uint64_t)));
		unsigned int byte = (unsigned int)(position % sizeof(uint64_t));

		while (byte < sizeof(uint64_t) && cursor < length) {
			buffer[cursor++] = (unsigned char)(word >> (byte * 8));
			byte++;
		}
	}
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

static int device_size_bytes(int fd, uint64_t *size)
{
	struct stat statbuf;

	if (!ioctl(fd, BLKGETSIZE64, size))
		return 0;
	if (errno != ENOTTY || fstat(fd, &statbuf) || !S_ISREG(statbuf.st_mode))
		return -1;
	*size = (uint64_t)statbuf.st_size;
	return 0;
}

static int checked_end(uint64_t start, uint64_t length, uint64_t *end)
{
	if (length > UINT64_MAX - start) {
		errno = EOVERFLOW;
		return -1;
	}
	*end = start + length;
	return 0;
}

static int aligned_span(uint64_t offset, uint64_t length,
			uint64_t *start, uint64_t *span)
{
	uint64_t end;
	uint64_t aligned_end;

	if (!length || checked_end(offset, length, &end))
		return -1;
	if (end > INT64_MAX) {
		errno = EOVERFLOW;
		return -1;
	}
	*start = offset & ~((uint64_t)MAP_BLOCK_BYTES - 1);
	if (end > UINT64_MAX - (MAP_BLOCK_BYTES - 1)) {
		errno = EOVERFLOW;
		return -1;
	}
	aligned_end = (end + MAP_BLOCK_BYTES - 1) &
		      ~((uint64_t)MAP_BLOCK_BYTES - 1);
	*span = aligned_end - *start;
	return 0;
}

static int initialize_expected(unsigned char *expected, uint64_t span,
			       uint64_t absolute_start, int baseline)
{
	uint64_t cursor;

	if (!baseline) {
		memset(expected, 0, (size_t)span);
		return 0;
	}

	for (cursor = 0; cursor < span; cursor += STREAM_CHUNK_BYTES) {
		size_t chunk = (size_t)((span - cursor) > STREAM_CHUNK_BYTES ?
			STREAM_CHUNK_BYTES : span - cursor);

		fill_pattern(expected + cursor, chunk, absolute_start + cursor,
			     BASELINE_SEED);
	}
	return 0;
}

static int write_baseline(int fd, const unsigned char *expected,
			  uint64_t absolute_start, uint64_t span)
{
	uint64_t cursor;

	for (cursor = 0; cursor < span; cursor += STREAM_CHUNK_BYTES) {
		size_t chunk = (size_t)((span - cursor) > STREAM_CHUNK_BYTES ?
			STREAM_CHUNK_BYTES : span - cursor);

		if (full_pwrite(fd, expected + cursor, chunk,
				(off_t)(absolute_start + cursor)))
			return -1;
	}
	return fdatasync(fd);
}

static int verify_expected(const char *device, const unsigned char *expected,
			   uint64_t absolute_start, uint64_t span)
{
	void *buffer = NULL;
	uint64_t cursor;
	int fd = -1;
	int allocation_error;
	int ret = -1;

	allocation_error = posix_memalign(&buffer, MAP_BLOCK_BYTES,
					 STREAM_CHUNK_BYTES);
	if (allocation_error) {
		errno = allocation_error;
		return -1;
	}
	fd = open(device, O_RDONLY | O_DIRECT | O_CLOEXEC);
	if (fd < 0)
		goto out;

	for (cursor = 0; cursor < span; cursor += STREAM_CHUNK_BYTES) {
		size_t chunk = (size_t)((span - cursor) > STREAM_CHUNK_BYTES ?
			STREAM_CHUNK_BYTES : span - cursor);

		if (full_pread(fd, buffer, chunk,
			       (off_t)(absolute_start + cursor)))
			goto out;
		if (memcmp(buffer, expected + cursor, chunk)) {
			fprintf(stderr,
				"byte-io: verification differs at aligned chunk offset=%" PRIu64 "\n",
				absolute_start + cursor);
			errno = EILSEQ;
			goto out;
		}
	}
	ret = 0;

out:
	if (fd >= 0)
		close(fd);
	free(buffer);
	return ret;
}

static int allocate_expected(uint64_t span, unsigned char **expected)
{
	if (span > SIZE_MAX) {
		errno = EOVERFLOW;
		return -1;
	}
	*expected = malloc((size_t)span);
	return *expected ? 0 : -1;
}

static int prepare_device(const char *device, uint64_t start, uint64_t span,
			  int baseline, unsigned char **expected, int *fd)
{
	uint64_t device_bytes;

	*fd = open(device, O_RDWR | O_CLOEXEC);
	if (*fd < 0)
		return -1;
	if (device_size_bytes(*fd, &device_bytes))
		return -1;
	if (span > device_bytes || start > device_bytes - span) {
		errno = EFBIG;
		return -1;
	}
	if (allocate_expected(span, expected) ||
	    initialize_expected(*expected, span, start, baseline))
		return -1;
	if (baseline && write_baseline(*fd, *expected, start, span))
		return -1;
	return 0;
}

static int write_patch(int fd, unsigned char *expected,
			uint64_t aligned_start, uint64_t offset,
			uint64_t length, uint64_t request, uint64_t seed)
{
	unsigned char *buffer;
	uint64_t cursor;
	size_t buffer_size;

	if (!request || request > SIZE_MAX) {
		errno = EINVAL;
		return -1;
	}
	buffer_size = (size_t)(request > length ? length : request);
	buffer = malloc(buffer_size);
	if (!buffer)
		return -1;

	for (cursor = 0; cursor < length; cursor += buffer_size) {
		size_t chunk = (size_t)((length - cursor) > buffer_size ?
			buffer_size : length - cursor);

		fill_pattern(buffer, chunk, offset + cursor, seed);
		memcpy(expected + (offset - aligned_start) + cursor,
		       buffer, chunk);
		if (full_pwrite(fd, buffer, chunk, (off_t)(offset + cursor))) {
			free(buffer);
			return -1;
		}
	}
	free(buffer);
	return 0;
}

static int command_exact(const char *operation, const char *device,
			 uint64_t offset, uint64_t length, uint64_t request,
			 uint64_t seed)
{
	unsigned char *expected = NULL;
	uint64_t start;
	uint64_t span;
	int baseline = !strcmp(operation, "update");
	int fd = -1;
	int ret = -1;
	int saved_errno;

	if (aligned_span(offset, length, &start, &span) ||
	    prepare_device(device, start, span, baseline, &expected, &fd) ||
	    write_patch(fd, expected, start, offset, length, request, seed) ||
	    fdatasync(fd))
		goto out;
	saved_errno = posix_fadvise(fd, (off_t)start, (off_t)span,
				    POSIX_FADV_DONTNEED);
	if (saved_errno) {
		errno = saved_errno;
		goto out;
	}
	if (close(fd)) {
		fd = -1;
		goto out;
	}
	fd = -1;
	if (verify_expected(device, expected, start, span))
		goto out;
	ret = 0;

out:
	saved_errno = errno;
	if (fd >= 0)
		close(fd);
	if (ret)
		fprintf(stderr, "byte-io %s: %s\n", operation,
			strerror(saved_errno));
	free(expected);
	errno = saved_errno;
	return ret;
}

static int command_randwrite(const char *device, uint64_t offset,
			     uint64_t range, uint64_t request,
			     uint64_t total, uint64_t seed)
{
	unsigned char *expected = NULL;
	unsigned char *buffer = NULL;
	uint64_t start;
	uint64_t span;
	uint64_t completed = 0;
	uint64_t operation = 0;
	int fd = -1;
	int ret = -1;
	int saved_errno;

	if (!range || !request || request > range || !total) {
		errno = EINVAL;
		goto out;
	}
	if (aligned_span(offset, range, &start, &span))
		goto out;
	if (request > SIZE_MAX) {
		errno = EOVERFLOW;
		goto out;
	}
	buffer = malloc((size_t)request);
	if (!buffer ||
	    prepare_device(device, start, span, 1, &expected, &fd))
		goto out;
	if (!seed)
		seed = UINT64_C(0x72616e6477726974);

	while (completed < total) {
		uint64_t length = request;
		uint64_t relative;
		uint64_t write_offset;
		uint64_t operation_seed;

		if (length > total - completed)
			length = total - completed;
		if (length > range)
			length = range;
		relative = range == length ? 0 :
			next_random(&seed) % (range - length + 1);
		write_offset = offset + relative;
		operation_seed = seed ^
			(operation * UINT64_C(0x9e3779b97f4a7c15));
		fill_pattern(buffer, (size_t)length, write_offset,
			     operation_seed);
		memcpy(expected + (write_offset - start), buffer,
		       (size_t)length);
		if (full_pwrite(fd, buffer, (size_t)length,
				(off_t)write_offset))
			goto out;
		completed += length;
		operation++;
	}
	if (fdatasync(fd))
		goto out;
	saved_errno = posix_fadvise(fd, (off_t)start, (off_t)span,
				    POSIX_FADV_DONTNEED);
	if (saved_errno) {
		errno = saved_errno;
		goto out;
	}
	if (close(fd)) {
		fd = -1;
		goto out;
	}
	fd = -1;
	if (verify_expected(device, expected, start, span))
		goto out;
	ret = 0;

out:
	saved_errno = errno;
	if (fd >= 0)
		close(fd);
	if (ret)
		fprintf(stderr, "byte-io randwrite: %s\n",
			strerror(saved_errno));
	free(buffer);
	free(expected);
	errno = saved_errno;
	return ret;
}

int main(int argc, char **argv)
{
	uint64_t offset;
	uint64_t first;
	uint64_t second;
	uint64_t third;
	uint64_t seed;

	if (argc == 7 &&
	    (!strcmp(argv[1], "write") || !strcmp(argv[1], "update"))) {
		if (parse_u64(argv[3], &offset) || parse_u64(argv[4], &first) ||
		    parse_u64(argv[5], &second) || parse_u64(argv[6], &seed) ||
		    !first || !second)
			goto invalid;
		return command_exact(argv[1], argv[2], offset, first, second, seed) ?
			EXIT_FAILURE : EXIT_SUCCESS;
	}
	if (argc == 8 && !strcmp(argv[1], "randwrite")) {
		if (parse_u64(argv[3], &offset) || parse_u64(argv[4], &first) ||
		    parse_u64(argv[5], &second) ||
		    parse_u64(argv[6], &third) ||
		    parse_u64(argv[7], &seed) || !first || !second || !third)
			goto invalid;
		return command_randwrite(argv[2], offset, first, second,
					 third, seed) ? EXIT_FAILURE : EXIT_SUCCESS;
	}

invalid:
	usage(argv[0]);
	return EXIT_FAILURE;
}
