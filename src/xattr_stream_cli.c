/*
 * xattr-stream CLI. Dogfoods the public C ABI: everything below reaches the
 * Zig core only through include/xattr_stream.h. All I/O lives here.
 *
 * Exit codes: 0 ok, 1 other error, 2 usage, 3 unsupported filesystem,
 * 4 missing attribute (get), 5 permission/read-only, 6 too large,
 * 7 path not found, 8 invalid name or path.
 */
#include "xattr_stream.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define SET_BINARY(fp) _setmode(_fileno(fp), _O_BINARY)
#else
#define SET_BINARY(fp) ((void)0)
#endif

#define PROG "xattr-stream"

enum {
	EXIT_OK = 0,
	EXIT_ERROR = 1,
	EXIT_USAGE = 2,
	EXIT_UNSUPPORTED = 3,
	EXIT_MISSING = 4,
	EXIT_PERMISSION = 5,
	EXIT_TOO_LARGE = 6,
	EXIT_NOT_FOUND = 7,
	EXIT_INVALID = 8
};

#define DEFAULT_LIMIT ((uint64_t)64 << 20)
#define READ_CHUNK ((size_t)64 * 1024)

typedef struct {
	xs_options xs;
	int json;
} cli_opts;

static int exit_for(int status) {
	switch (status) {
	case XS_OK: return EXIT_OK;
	case XS_UNSUPPORTED: return EXIT_UNSUPPORTED;
	case XS_MISSING: return EXIT_MISSING;
	case XS_PERMISSION:
	case XS_READ_ONLY: return EXIT_PERMISSION;
	case XS_TOO_LARGE: return EXIT_TOO_LARGE;
	case XS_NOT_FOUND: return EXIT_NOT_FOUND;
	case XS_INVALID_NAME:
	case XS_INVALID_PATH: return EXIT_INVALID;
	default: return EXIT_ERROR;
	}
}

static const char *explain(int status) {
	switch (status) {
	case XS_MISSING: return "attribute not present";
	case XS_UNSUPPORTED: return "filesystem does not support attributes (not evidence of tampering)";
	case XS_READ_ONLY: return "filesystem is read-only";
	case XS_PERMISSION: return "permission denied";
	case XS_TOO_LARGE: return "value exceeds the size limit";
	case XS_NOT_FOUND: return "path not found";
	case XS_INVALID_NAME: return "invalid attribute name";
	case XS_INVALID_PATH: return "invalid path";
	case XS_CHANGED: return "value kept changing while reading";
	case XS_BUFFER_TOO_SMALL: return "buffer too small";
	case XS_OUT_OF_MEMORY: return "out of memory";
	case XS_INVALID_ARGUMENT: return "invalid argument";
	default: return "I/O error";
	}
}

static void usage(FILE *out) {
	fputs(
		"Usage:\n"
		"  " PROG " [options] put|set <path> <name>   value from stdin\n"
		"  " PROG " [options] get <path> <name>       value to stdout\n"
		"  " PROG " [options] len <path> <name>       byte length, or -1 if missing\n"
		"  " PROG " [options] del <path> <name>       delete (no error if missing)\n"
		"  " PROG " [options] lst|list <path>         names, one per line\n"
		"  " PROG " [options] limits [<path>]         max value bytes on that filesystem, or -1\n"
		"  " PROG " --help | -h | --version | --about\n"
		"\n"
		"Options (any order, before or after the command; -- ends options):\n"
		"  --nofollow      operate on a symlink itself, not its target\n"
		"  --raw           use native OS names (e.g. Linux user.x, macOS com.apple.x)\n"
		"  --limit <n>     max value size in bytes for put/get (default 67108864)\n"
		"  --json          JSON on stdout for len/lst/limits and JSON errors on stderr\n"
		"\n"
		"Names: 1..127 bytes UTF-8, no control chars or / \\ : * ? \" < > |, no\n"
		"leading/trailing space or trailing dot, not $..., com.apple..., Zone.Identifier.\n"
		"Linux stores them as user.<name>; macOS and Windows (NTFS streams) verbatim.\n"
		"\n"
		"Exit codes: 0 ok, 1 error, 2 usage, 3 unsupported fs, 4 missing, 5 permission,\n"
		"6 too large, 7 path not found, 8 invalid name/path.\n",
		out);
}

static void json_string(FILE *out, const unsigned char *s, size_t len) {
	fputc('"', out);
	for (size_t i = 0; i < len; i++) {
		unsigned char c = s[i];
		if (c == '"' || c == '\\') {
			fputc('\\', out);
			fputc(c, out);
		} else if (c < 0x20) {
			fprintf(out, "\\u%04x", c);
		} else {
			fputc(c, out);
		}
	}
	fputc('"', out);
}

static void report(const cli_opts *o, const char *op, const char *path, const char *name, int status) {
	const char *sname = xs_status_name(status);
	int32_t os_err = xs_last_os_error();
	if (o->json) {
		fputs("{\"status\":", stderr);
		json_string(stderr, (const unsigned char *)sname, strlen(sname));
		fputs(",\"op\":", stderr);
		json_string(stderr, (const unsigned char *)op, strlen(op));
		if (path) {
			fputs(",\"path\":", stderr);
			json_string(stderr, (const unsigned char *)path, strlen(path));
		}
		if (name) {
			fputs(",\"name\":", stderr);
			json_string(stderr, (const unsigned char *)name, strlen(name));
		}
		fprintf(stderr, ",\"os_error\":%" PRId32 ",\"message\":", os_err);
		json_string(stderr, (const unsigned char *)explain(status), strlen(explain(status)));
		fputs("}\n", stderr);
	} else {
		fprintf(stderr, PROG ": %s: %s%s%s: %s: %s (os error %" PRId32 ")\n",
			op, path ? path : "", name ? ": " : "", name ? name : "", sname, explain(status), os_err);
	}
}

/* Reads stdin into RAM, bounded: stops as soon as limit is exceeded. Returns
 * 0 ok, XS_TOO_LARGE, or XS_IO. */
static int read_stdin(uint64_t limit, unsigned char **out, size_t *out_len) {
	size_t cap = READ_CHUNK, len = 0;
	unsigned char *buf = malloc(cap);
	if (!buf) return XS_OUT_OF_MEMORY;
	for (;;) {
		if (len == cap) {
			if (cap > SIZE_MAX / 2) { free(buf); return XS_TOO_LARGE; }
			unsigned char *nb = realloc(buf, cap * 2);
			if (!nb) { free(buf); return XS_OUT_OF_MEMORY; }
			buf = nb;
			cap *= 2;
		}
		size_t want = cap - len;
		if ((uint64_t)len + want > limit + 1) want = (size_t)(limit + 1 - len);
		size_t n = fread(buf + len, 1, want, stdin);
		len += n;
		if ((uint64_t)len > limit) { free(buf); return XS_TOO_LARGE; }
		if (n < want) {
			if (ferror(stdin)) { free(buf); return XS_IO; }
			break;
		}
	}
	*out = buf;
	*out_len = len;
	return XS_OK;
}

static int write_all(FILE *out, const unsigned char *p, size_t len) {
	while (len > 0) {
		size_t n = fwrite(p, 1, len, out);
		if (n == 0) return -1;
		p += n;
		len -= n;
	}
	return fflush(out) == 0 ? 0 : -1;
}

static int parse_u64(const char *s, uint64_t *out) {
	if (!s || !*s) return -1;
	char *end = NULL;
	errno = 0;
	unsigned long long v = strtoull(s, &end, 10);
	if (errno != 0 || *end != '\0' || s[0] == '-') return -1;
	*out = (uint64_t)v;
	return 0;
}

static int cmd_put(const cli_opts *o, const char *path, const char *name) {
	unsigned char *buf = NULL;
	size_t len = 0;
	SET_BINARY(stdin);
	int st = read_stdin(o->xs.max_value_len, &buf, &len);
	if (st != XS_OK) {
		report(o, "put", "<stdin>", NULL, st);
		return exit_for(st);
	}
	st = xs_set(path, strlen(path), name, strlen(name), buf, len, &o->xs);
	free(buf);
	if (st != XS_OK) report(o, "put", path, name, st);
	return exit_for(st);
}

static int cmd_get(const cli_opts *o, const char *path, const char *name) {
	xs_buffer b = {0};
	int st = xs_get(path, strlen(path), name, strlen(name), &o->xs, &b);
	if (st != XS_OK) {
		report(o, "get", path, name, st);
		return exit_for(st);
	}
	SET_BINARY(stdout);
	int rc = write_all(stdout, b.data, b.len);
	xs_buffer_free(&b);
	if (rc != 0) {
		report(o, "get", "<stdout>", NULL, XS_IO);
		return EXIT_ERROR;
	}
	return EXIT_OK;
}

static int cmd_len(const cli_opts *o, const char *path, const char *name) {
	uint64_t len = 0;
	int st = xs_size(path, strlen(path), name, strlen(name), &o->xs, &len);
	if (st == XS_MISSING) {
		puts(o->json ? "{\"len\":-1}" : "-1");
		return EXIT_OK;
	}
	if (st != XS_OK) {
		report(o, "len", path, name, st);
		return exit_for(st);
	}
	if (o->json) printf("{\"len\":%" PRIu64 "}\n", len);
	else printf("%" PRIu64 "\n", len);
	return EXIT_OK;
}

static int cmd_del(const cli_opts *o, const char *path, const char *name) {
	int st = xs_remove(path, strlen(path), name, strlen(name), &o->xs);
	if (st == XS_MISSING) return EXIT_OK;
	if (st != XS_OK) report(o, "del", path, name, st);
	return exit_for(st);
}

static int cmd_lst(const cli_opts *o, const char *path) {
	xs_buffer b = {0};
	size_t count = 0;
	int st = xs_list(path, strlen(path), &o->xs, &b, &count);
	if (st != XS_OK) {
		report(o, "lst", path, NULL, st);
		return exit_for(st);
	}
	const unsigned char *p = b.data;
	size_t off = 0;
	if (o->json) fputc('[', stdout);
	for (size_t i = 0; i < count; i++) {
		size_t n = strlen((const char *)p + off);
		if (o->json) {
			if (i) fputc(',', stdout);
			json_string(stdout, p + off, n);
		} else {
			fwrite(p + off, 1, n, stdout);
			fputc('\n', stdout);
		}
		off += n + 1;
	}
	if (o->json) fputs("]\n", stdout);
	xs_buffer_free(&b);
	return fflush(stdout) == 0 ? EXIT_OK : EXIT_ERROR;
}

static int cmd_limits(const cli_opts *o, const char *path) {
	int64_t n = xs_limits(path, strlen(path));
	if (o->json) printf("{\"max_value_bytes\":%" PRId64 "}\n", n);
	else printf("%" PRId64 "\n", n);
	return EXIT_OK;
}

int main(int argc, char **argv) {
	cli_opts o;
	memset(&o, 0, sizeof o);
	o.xs.max_value_len = DEFAULT_LIMIT;

	const char *pos[3] = {0};
	int npos = 0;
	int only_positional = 0;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!only_positional && a[0] == '-' && a[1] != '\0') {
			if (strcmp(a, "--") == 0) { only_positional = 1; continue; }
			if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) { usage(stdout); return EXIT_OK; }
			if (strcmp(a, "--version") == 0) { printf(PROG " %s\n", xs_version()); return EXIT_OK; }
			if (strcmp(a, "--about") == 0) {
				printf(PROG " %s: cross-platform binary-safe file attributes (xattrs / NTFS streams) for %s\n",
					xs_version(), xs_target());
				return EXIT_OK;
			}
			if (strcmp(a, "--nofollow") == 0) { o.xs.flags |= XS_FLAG_NOFOLLOW; continue; }
			if (strcmp(a, "--raw") == 0) { o.xs.flags |= XS_FLAG_RAW_NAMES; continue; }
			if (strcmp(a, "--json") == 0) { o.json = 1; continue; }
			if (strcmp(a, "--limit") == 0) {
				if (i + 1 >= argc || parse_u64(argv[++i], &o.xs.max_value_len) != 0) {
					fprintf(stderr, PROG ": --limit needs a non-negative integer\n");
					usage(stderr);
					return EXIT_USAGE;
				}
				continue;
			}
			fprintf(stderr, PROG ": unknown option '%s'\n", a);
			usage(stderr);
			return EXIT_USAGE;
		}
		if (npos == 3) { usage(stderr); return EXIT_USAGE; }
		pos[npos++] = a;
	}

	if (npos == 0) { usage(stderr); return EXIT_USAGE; }
	const char *cmd = pos[0];
	int nargs = npos - 1;

	if (strcmp(cmd, "put") == 0 || strcmp(cmd, "set") == 0) {
		if (nargs != 2) { usage(stderr); return EXIT_USAGE; }
		return cmd_put(&o, pos[1], pos[2]);
	}
	if (strcmp(cmd, "get") == 0) {
		if (nargs != 2) { usage(stderr); return EXIT_USAGE; }
		return cmd_get(&o, pos[1], pos[2]);
	}
	if (strcmp(cmd, "len") == 0) {
		if (nargs != 2) { usage(stderr); return EXIT_USAGE; }
		return cmd_len(&o, pos[1], pos[2]);
	}
	if (strcmp(cmd, "del") == 0) {
		if (nargs != 2) { usage(stderr); return EXIT_USAGE; }
		return cmd_del(&o, pos[1], pos[2]);
	}
	if (strcmp(cmd, "lst") == 0 || strcmp(cmd, "list") == 0) {
		if (nargs != 1) { usage(stderr); return EXIT_USAGE; }
		return cmd_lst(&o, pos[1]);
	}
	if (strcmp(cmd, "limits") == 0) {
		if (nargs > 1) { usage(stderr); return EXIT_USAGE; }
		return cmd_limits(&o, nargs == 1 ? pos[1] : ".");
	}
	fprintf(stderr, PROG ": unknown command '%s'\n", cmd);
	usage(stderr);
	return EXIT_USAGE;
}
