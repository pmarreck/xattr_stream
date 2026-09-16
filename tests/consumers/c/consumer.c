/*
 * Independent C consumer of the public header, compiled with a compiler
 * other than Zig's (clang, -std=c99 -pedantic) against libxattr_stream.a.
 * Creates its own fixture file in the current directory and removes it.
 */
#include "xattr_stream.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)

int main(void) {
	const char *path = "xs_consumer_c.tmp";
	FILE *f = fopen(path, "wb");
	if (!f) { perror("fopen"); return 1; }
	fclose(f);

	unsigned char all[256];
	for (int i = 0; i < 256; i++) all[i] = (unsigned char)i;

	int st = xs_set(path, strlen(path), "probe", 5, all, sizeof all, NULL);
	if (st == XS_UNSUPPORTED) {
		fprintf(stderr, "SKIP: filesystem does not support attributes\n");
		remove(path);
		return 0;
	}
	CHECK(st == XS_OK, "xs_set");

	uint64_t len = 0;
	CHECK(xs_size(path, strlen(path), "probe", 5, NULL, &len) == XS_OK && len == 256, "xs_size == 256");

	xs_buffer b = {0};
	CHECK(xs_get(path, strlen(path), "probe", 5, NULL, &b) == XS_OK, "xs_get");
	CHECK(b.len == 256 && memcmp(b.data, all, 256) == 0, "round trip bytes");
	xs_buffer_free(&b);
	CHECK(b.data == NULL && b.len == 0, "xs_buffer_free zeroes");

	unsigned char small[16];
	size_t got = 0;
	CHECK(xs_get_into(path, strlen(path), "probe", 5, small, sizeof small, NULL, &got) == XS_BUFFER_TOO_SMALL, "get_into too small");

	xs_buffer names = {0};
	size_t count = 0;
	CHECK(xs_list(path, strlen(path), NULL, &names, &count) == XS_OK && count == 1, "xs_list count 1");
	CHECK(names.len == 6 && memcmp(names.data, "probe\0", 6) == 0, "xs_list packing");
	xs_buffer_free(&names);

	CHECK(xs_set(path, strlen(path), "a:b", 3, "v", 1, NULL) == XS_INVALID_NAME, "invalid name");
	CHECK(strcmp(xs_status_name(XS_INVALID_NAME), "XS_INVALID_NAME") == 0, "status name");
	CHECK(xs_remove(path, strlen(path), "probe", 5, NULL) == XS_OK, "xs_remove");
	CHECK(xs_remove(path, strlen(path), "probe", 5, NULL) == XS_MISSING, "remove again is missing");
	CHECK(xs_size(path, strlen(path), "probe", 5, NULL, &len) == XS_MISSING, "size after remove");
	CHECK(strcmp(xs_version(), XS_VERSION) == 0, "version matches header");

	remove(path);
	if (failures == 0) printf("C consumer: ok (%s, %s)\n", xs_version(), xs_target());
	return failures;
}
