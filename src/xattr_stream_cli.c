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
#include <windows.h>
#define SET_BINARY(fp) _setmode(_fileno(fp), _O_BINARY)
#define STDOUT_IS_TTY() _isatty(_fileno(stdout))
#else
#include <unistd.h>
#define SET_BINARY(fp) ((void)0)
#define STDOUT_IS_TTY() isatty(STDOUT_FILENO)
#endif

/* 256-color ANSI: names in bright orange, values in light blue. */
#define ANSI_NAME "\x1b[38;5;208m"
#define ANSI_VALUE "\x1b[38;5;117m"
#define ANSI_RESET "\x1b[0m"

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

#define DEFAULT_LIMIT ((uint64_t)XS_DEFAULT_MAX_VALUE_LEN)
#define READ_CHUNK ((size_t)64 * 1024)

typedef struct {
	xs_options xs;
	int json;
	int quiet;
	int recurse;
	int64_t max_depth; /* -1 = unlimited; 0 = the path alone */
	int depth_first;
	int values;
	int debug; /* --debug, or DEBUG env set to anything but "" or "0" */
	int color; /* -1 auto (tty and no NO_COLOR), 0 off, 1 forced */
	int use_color; /* resolved for this run */
} cli_opts;

/* Colors go only to an interactive terminal, never into JSON or a pipe. */
static int resolve_color(const cli_opts *o) {
	if (o->json) return 0;
	if (o->color == 1) return 1;
	if (o->color == 0) return 0;
	const char *nc = getenv("NO_COLOR");
	if (nc && *nc) return 0;
	if (!STDOUT_IS_TTY()) return 0;
#ifdef _WIN32
	HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
	DWORD mode = 0;
	if (h == INVALID_HANDLE_VALUE || !GetConsoleMode(h, &mode)) return 0;
	if (!SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) return 0;
#endif
	return 1;
}

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
		"  " PROG " [options] dump <path>             names and values (alias: lst --values)\n"
		"  " PROG " [options] limits [<path>]         max value bytes on that filesystem, or -1\n"
		"  " PROG " --help | -h | --version | --about\n"
		"\n"
		"Options (any order, before or after the command; -- ends options):\n"
		"  --nofollow      operate on a symlink itself, not its target\n"
		"  --raw           use native OS names (e.g. Linux user.x, macOS com.apple.x)\n"
		"  --limit <n>     max value size in bytes for put/get (default 65536, the\n"
		"                  smallest OS ceiling; macOS and NTFS allow more)\n"
		"  --json          JSON on stdout for len/lst/limits and JSON errors on stderr\n"
		"  --quiet         suppress warnings (e.g. values over 4096 bytes)\n"
		"  -r, --recurse   lst/dump: walk the tree below <path>, breadth-first\n"
		"  -d, --depth <n> lst/dump: limit the walk to n levels (0 = <path> alone);\n"
		"                  implies --recurse; also -d=<n> / --depth=<n>\n"
		"  --depth-first   lst/dump: walk depth-first (pre-order) instead\n"
		"  --values        lst: show values; printable UTF-8 as text, else as hex\n"
		"  --debug         also report what a recursive walk skipped, e.g. dangling\n"
		"                  symlinks (or set the DEBUG environment variable)\n"
		"  --color         force ANSI color in listings (default: only on a terminal,\n"
		"                  and never when NO_COLOR is set)\n"
		"  --no-color      never emit ANSI (aliases: --no-ansi, --simple)\n"
		"\n"
		"Listing columns are tab-separated: [path] name [text|hex value]. The path\n"
		"column appears when recursing; the value columns with --values/dump.\n"
		"Children are visited in bytewise order; symlinks are listed but never entered.\n"
		"\n"
		"Names: 1..127 bytes UTF-8, no control chars or / \\ : * ? \" < > |, no\n"
		"leading/trailing space or trailing dot, not $..., com.apple..., Zone.Identifier,\n"
		"and not starting with user. (Linux stores every name as user.<name> itself;\n"
		"macOS and Windows NTFS streams store it verbatim).\n"
		"Values over 4096 bytes draw a warning: ext4 without ea_inode fits about one\n"
		"4 KiB block of attributes per file.\n"
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

static void warn_portability(const cli_opts *o, size_t len) {
	if (o->quiet || len <= XS_PORTABLE_VALUE_LEN) return;
	if (o->json) {
		fprintf(stderr, "{\"warning\":\"portability\",\"bytes\":%zu,\"portable_max\":%d,\"message\":"
			"\"values over %d bytes may not fit on ext4 without the ea_inode feature\"}\n",
			len, XS_PORTABLE_VALUE_LEN, XS_PORTABLE_VALUE_LEN);
	} else {
		fprintf(stderr, PROG ": warning: value is %zu bytes; values over %d bytes may not fit on ext4 without the ea_inode feature\n",
			len, XS_PORTABLE_VALUE_LEN);
	}
}

static void report(const cli_opts *o, const char *op, const char *path, const char *name, int status) {
	const char *sname = xs_status_name(status);
	int32_t os_err = xs_last_os_error();
	int reason = XS_NAME_OK;
	if (status == XS_INVALID_NAME && name) reason = xs_validate_name(name, strlen(name), &o->xs);
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
		if (reason != XS_NAME_OK) {
			const char *rn = xs_name_rejection_name(reason);
			const char *rm = xs_name_rejection_message(reason);
			fputs(",\"reason\":", stderr);
			json_string(stderr, (const unsigned char *)rn, strlen(rn));
			fputs(",\"reason_message\":", stderr);
			json_string(stderr, (const unsigned char *)rm, strlen(rm));
		}
		fputs("}\n", stderr);
	} else {
		fprintf(stderr, PROG ": %s: %s%s%s: %s: %s (os error %" PRId32 ")\n",
			op, path ? path : "", name ? ": " : "", name ? name : "", sname, explain(status), os_err);
		if (reason != XS_NAME_OK) fprintf(stderr, PROG ": %s\n", xs_name_rejection_message(reason));
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
	warn_portability(o, len);
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

/* ---- listing (single path or walked tree) -------------------------------- */

typedef struct {
	const cli_opts *o;
	int json_first;
	int failures;
} lst_ctx;

static void print_hex(FILE *out, const unsigned char *p, size_t n) {
	static const char hx[] = "0123456789abcdef";
	for (size_t i = 0; i < n; i++) {
		fputc(hx[p[i] >> 4], out);
		fputc(hx[p[i] & 15], out);
	}
}

static void warn_path(lst_ctx *c, const char *path, size_t path_len, const unsigned char *name, size_t name_len, int status) {
	c->failures++;
	if (c->o->quiet) return;
	const char *sname = xs_status_name(status);
	if (c->o->json) {
		fputs("{\"warning\":", stderr);
		json_string(stderr, (const unsigned char *)sname, strlen(sname));
		fputs(",\"path\":", stderr);
		json_string(stderr, (const unsigned char *)path, path_len);
		if (name) {
			fputs(",\"name\":", stderr);
			json_string(stderr, name, name_len);
		}
		fprintf(stderr, ",\"os_error\":%" PRId32 ",\"message\":", xs_last_os_error());
		json_string(stderr, (const unsigned char *)explain(status), strlen(explain(status)));
		fputs("}\n", stderr);
	} else {
		fprintf(stderr, PROG ": warning: %.*s%s%.*s: %s: %s (os error %" PRId32 ")\n",
			(int)path_len, path, name ? ": " : "", name ? (int)name_len : 0, name ? (const char *)name : "",
			sname, explain(status), xs_last_os_error());
	}
}

static void emit_entry(lst_ctx *c, const char *path, size_t path_len, const unsigned char *name, size_t name_len) {
	const cli_opts *o = c->o;
	xs_buffer v = {0};
	int is_text = 0;
	if (o->values) {
		int st = xs_get(path, path_len, (const char *)name, name_len, &o->xs, &v);
		if (st != XS_OK) {
			warn_path(c, path, path_len, name, name_len, st);
			return;
		}
		is_text = xs_is_display_text(v.data, v.len);
	}
	if (o->json) {
		if (!c->json_first) fputc(',', stdout);
		c->json_first = 0;
		if (!o->recurse && !o->values) {
			json_string(stdout, name, name_len); /* plain ["a","b"] form */
		} else {
			fputc('{', stdout);
			if (o->recurse) {
				fputs("\"path\":", stdout);
				json_string(stdout, (const unsigned char *)path, path_len);
				fputc(',', stdout);
			}
			fputs("\"name\":", stdout);
			json_string(stdout, name, name_len);
			if (o->values) {
				fputs(is_text ? ",\"text\":" : ",\"hex\":", stdout);
				if (is_text) {
					json_string(stdout, v.data, v.len);
				} else {
					fputc('"', stdout);
					print_hex(stdout, v.data, v.len);
					fputc('"', stdout);
				}
			}
			fputc('}', stdout);
		}
	} else {
		if (o->recurse) {
			fwrite(path, 1, path_len, stdout);
			fputc('\t', stdout);
		}
		if (o->use_color) fputs(ANSI_NAME, stdout);
		fwrite(name, 1, name_len, stdout);
		if (o->use_color) fputs(ANSI_RESET, stdout);
		if (o->values) {
			fputs(is_text ? "\ttext\t" : "\thex\t", stdout);
			if (o->use_color) fputs(ANSI_VALUE, stdout);
			if (is_text) fwrite(v.data, 1, v.len, stdout);
			else print_hex(stdout, v.data, v.len);
			if (o->use_color) fputs(ANSI_RESET, stdout);
		}
		fputc('\n', stdout);
	}
	if (o->values) xs_buffer_free(&v);
}

static int list_one(lst_ctx *c, const char *path, size_t path_len) {
	xs_buffer names = {0};
	size_t count = 0;
	int st = xs_list(path, path_len, &c->o->xs, &names, &count);
	if (st != XS_OK) return st;
	const unsigned char *p = names.data;
	size_t off = 0;
	for (size_t i = 0; i < count; i++) {
		size_t n = strlen((const char *)p + off);
		emit_entry(c, path, path_len, p + off, n);
		off += n + 1;
	}
	xs_buffer_free(&names);
	return XS_OK;
}

static int walk_cb(void *ud, const char *path, size_t path_len, int kind, uint64_t depth, int status) {
	lst_ctx *c = (lst_ctx *)ud;
	(void)depth;
	if (status != XS_OK) {
		warn_path(c, path, path_len, NULL, 0, status);
		return 0;
	}
	int st = list_one(c, path, path_len);
	/* A symlink whose target is gone has nothing to list; that is the link's
	 * state, not an error in the walk, so it is skipped without noise unless
	 * the user asked to see skips. */
	if (st == XS_NOT_FOUND && kind == XS_KIND_SYMLINK) {
		if (c->o->debug) {
			if (c->o->json) {
				fputs("{\"debug\":\"dangling_symlink\",\"path\":", stderr);
				json_string(stderr, (const unsigned char *)path, path_len);
				fputs("}\n", stderr);
			} else {
				fprintf(stderr, PROG ": debug: %.*s: dangling symlink, skipped\n", (int)path_len, path);
			}
		}
		return 0;
	}
	if (st != XS_OK) warn_path(c, path, path_len, NULL, 0, st);
	return 0;
}

static int cmd_lst(cli_opts *o, const char *path) {
	o->use_color = resolve_color(o);
	lst_ctx c = { o, 1, 0 };
	if (o->json) fputc('[', stdout);
	int st;
	if (o->recurse) {
		st = xs_walk(path, strlen(path), o->depth_first ? XS_WALK_DEPTH_FIRST : XS_WALK_BREADTH_FIRST,
			o->max_depth, walk_cb, &c);
	} else {
		st = list_one(&c, path, strlen(path));
	}
	if (o->json) fputs("]\n", stdout);
	if (st != XS_OK) {
		report(o, "lst", path, NULL, st);
		return exit_for(st);
	}
	if (fflush(stdout) != 0) return EXIT_ERROR;
	return c.failures ? EXIT_ERROR : EXIT_OK;
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
	o.max_depth = -1;
	o.color = -1;
	const char *dbg = getenv("DEBUG");
	if (dbg && *dbg && strcmp(dbg, "0") != 0) o.debug = 1;

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
			if (strcmp(a, "--quiet") == 0) { o.quiet = 1; continue; }
			if (strcmp(a, "-r") == 0 || strcmp(a, "--recurse") == 0) { o.recurse = 1; continue; }
			if (strcmp(a, "--depth-first") == 0) { o.depth_first = 1; continue; }
			if (strcmp(a, "--values") == 0) { o.values = 1; continue; }
			if (strcmp(a, "--debug") == 0) { o.debug = 1; continue; }
			if (strcmp(a, "--color") == 0) { o.color = 1; continue; }
			if (strcmp(a, "--no-color") == 0 || strcmp(a, "--no-ansi") == 0 || strcmp(a, "--simple") == 0) { o.color = 0; continue; }
			if (strcmp(a, "-d") == 0 || strcmp(a, "--depth") == 0 ||
			    strncmp(a, "-d=", 3) == 0 || strncmp(a, "--depth=", 8) == 0) {
				const char *num = strchr(a, '=');
				if (num) num++;
				else if (i + 1 < argc) num = argv[++i];
				uint64_t d = 0;
				if (parse_u64(num, &d) != 0 || d > INT64_MAX) {
					fprintf(stderr, PROG ": --depth needs a non-negative integer\n");
					usage(stderr);
					return EXIT_USAGE;
				}
				o.max_depth = (int64_t)d;
				o.recurse = 1;
				continue;
			}
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
	if (strcmp(cmd, "lst") == 0 || strcmp(cmd, "list") == 0 || strcmp(cmd, "dump") == 0) {
		if (nargs != 1) { usage(stderr); return EXIT_USAGE; }
		if (strcmp(cmd, "dump") == 0) o.values = 1;
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
