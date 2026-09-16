/*
 * xattr-stream CLI. Dogfoods the public C ABI: everything below reaches the
 * Zig core only through include/xattr_stream.h. All I/O lives here.
 *
 * Exit codes: 0 ok, 1 other error, 2 usage, 3 unsupported filesystem,
 * 4 missing attribute (get), 5 permission/read-only, 6 too large,
 * 7 path not found, 8 invalid name or path.
 */
#include "xattr_stream.h"
#include "printable_binary.h" /* binary values in listings, via its own C ABI */

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

typedef enum { FMT_TSV = 0, FMT_CSV, FMT_TABLE, FMT_MD } out_fmt;
#define MAX_COLS 4

typedef struct {
	xs_options xs;
	int json;
	out_fmt fmt;       /* --tsv (default) | --csv | --table | --md */
	int utf8;          /* --utf8: printable UTF-8 values verbatim, plus a type column */
	size_t cols[MAX_COLS]; /* --cols widths for the present columns, in order */
	size_t cols_n;
	int quiet;
	int recurse;
	int64_t max_depth; /* -1 = unlimited; 0 = the path alone */
	int depth_first;
	int values;
	int debug; /* --debug, or DEBUG env set to anything but "" or "0" */
	int hex;   /* --hex: binary values as hex instead of printable-binary */
	size_t max_width; /* -w/--max-width: displayed value chars, 0 = unlimited */
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
		"  " PROG " [options] dmp|dump <path>         names and values (alias: lst --values)\n"
		"  " PROG " [options] lim|limits [<path>]     max value bytes on that filesystem, or -1\n"
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
		"  --values        lst: show values through printable-binary (one reversible\n"
		"                  line per value; decode with `printable-binary -d`)\n"
		"  --hex           show values as lowercase hex instead of printable-binary\n"
		"  --utf8          show values that are printable single-line UTF-8 verbatim and\n"
		"                  add a type column (utf8 | pb | hex)\n"
		"  --tsv           tab-separated rows, no header (default)\n"
		"  --csv           comma-separated rows with a header; names and values go\n"
		"                  through printable-binary so no delimiter can appear\n"
		"  --table         ASCII table; paths truncate on the left, other cells on the\n"
		"                  right (default widths: path 48, name 24, type 4, value 40)\n"
		"  --md, --markdown  Markdown table with the same widths\n"
		"  --cols <a,b,..> column widths in display order ([path,] name, [type,] value);\n"
		"                  0 = no truncation; implies --table unless --md is given\n"
		"  -w, --max-width <n>  cut displayed values after n characters, appending\n"
		"                  ...(N bytes); 0 = unlimited; never applies to --json\n"
		"  --debug         also report what a recursive walk skipped: dangling symlinks\n"
		"                  and entries deleted mid-walk (or set the DEBUG env var)\n"
		"  --color         force ANSI color in listings (default: only on a terminal,\n"
		"                  and never when NO_COLOR is set)\n"
		"  --no-color      never emit ANSI (aliases: --no-ansi, --simple)\n"
		"\n"
		"Listing columns: [path] name [type] value. The path column appears when\n"
		"recursing, the value with --values/dump, the type only with --utf8.\n"
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

enum { COL_PATH, COL_NAME, COL_TYPE, COL_VALUE, COL_COUNT };
static const char *const col_label[COL_COUNT] = { "path", "name", "type", "value" };
static const size_t col_default_width[COL_COUNT] = { 48, 24, 4, 40 };

typedef struct {
	const cli_opts *o;
	int json_first;
	int failures;
	int present[COL_COUNT];
	size_t width[COL_COUNT]; /* 0 = no truncation, no padding */
} lst_ctx;

static char *hex_alloc(const unsigned char *p, size_t n) {
	static const char hx[] = "0123456789abcdef";
	char *s = malloc(n * 2 + 1);
	if (!s) return NULL;
	for (size_t i = 0; i < n; i++) {
		s[2 * i] = hx[p[i] >> 4];
		s[2 * i + 1] = hx[p[i] & 15];
	}
	s[2 * n] = '\0';
	return s;
}

/* Code points in valid UTF-8: every byte that is not a 10xxxxxx continuation. */
static size_t utf8_count(const unsigned char *p, size_t len) {
	size_t n = 0;
	for (size_t i = 0; i < len; i++) if ((p[i] & 0xC0) != 0x80) n++;
	return n;
}

/* Byte length of the first max_chars code points, so a cut never splits a glyph. */
static size_t utf8_prefix_bytes(const unsigned char *p, size_t len, size_t max_chars) {
	size_t chars = 0, i = 0;
	while (i < len) {
		if ((p[i] & 0xC0) != 0x80) {
			if (chars == max_chars) break;
			chars++;
		}
		i++;
	}
	return i;
}

/* Byte offset where the last max_chars code points begin. */
static size_t utf8_suffix_start(const unsigned char *p, size_t len, size_t max_chars) {
	size_t chars = 0, i = len;
	while (i > 0) {
		i--;
		if ((p[i] & 0xC0) != 0x80) {
			chars++;
			if (chars == max_chars) return i;
		}
	}
	return 0;
}

/* A displayed value: which representation it uses and the bytes to show. */
typedef struct {
	const char *type;        /* "utf8", "pb" or "hex" */
	const unsigned char *bytes;
	size_t len;
	pb_ffi_result_t pb;
	char *hex;
} value_disp;

static value_disp render_value(const cli_opts *o, const unsigned char *raw, size_t raw_len) {
	value_disp d = { "hex", raw, raw_len, {0}, NULL };
	/* CSV always uses printable-binary so no delimiter can appear in a value. */
	if (o->utf8 && o->fmt != FMT_CSV && xs_is_display_text(raw, raw_len)) {
		d.type = "utf8";
		return d;
	}
	if (!o->hex) {
		d.pb = pb_encode((const char *)raw, raw_len, PB_ENCODE_NONE, NULL, 0);
		if (d.pb.error_code == 0 && (d.pb.data || d.pb.len == 0)) {
			d.type = "pb";
			d.bytes = (const unsigned char *)d.pb.data;
			d.len = d.pb.len;
			return d;
		}
		if (d.pb.data) { pb_free(d.pb.data, d.pb.len); d.pb.data = NULL; }
	}
	d.hex = hex_alloc(raw, raw_len);
	if (d.hex) {
		d.bytes = (const unsigned char *)d.hex;
		d.len = raw_len * 2;
	}
	return d;
}

static void free_value(value_disp *d) {
	if (d->pb.data) pb_free(d->pb.data, d->pb.len);
	free(d->hex);
	d->pb.data = NULL;
	d->hex = NULL;
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

/* ---- cell rendering for table / markdown --------------------------------- */

/* Truncate to `width` code points (0 = unlimited): paths keep their end
 * (left ellipsis), everything else keeps its start. Returns a malloc'd
 * NUL-terminated string. */
static char *fit_cell(const unsigned char *s, size_t len, size_t width, int keep_end) {
	static const char ell[] = "\xe2\x80\xa6";
	size_t cps = utf8_count(s, len);
	if (width == 0 || cps <= width) {
		char *out = malloc(len + 1);
		if (!out) return NULL;
		memcpy(out, s, len);
		out[len] = '\0';
		return out;
	}
	size_t keep = width - 1;
	if (keep_end) {
		size_t start = keep == 0 ? len : utf8_suffix_start(s, len, keep);
		size_t n = len - start;
		char *out = malloc(3 + n + 1);
		if (!out) return NULL;
		memcpy(out, ell, 3);
		memcpy(out + 3, s + start, n);
		out[3 + n] = '\0';
		return out;
	}
	size_t n = utf8_prefix_bytes(s, len, keep);
	char *out = malloc(n + 3 + 1);
	if (!out) return NULL;
	memcpy(out, s, n);
	memcpy(out + n, ell, 3);
	out[n + 3] = '\0';
	return out;
}

/* Replace every | with `repl` (table: U+2223 DIVIDES, markdown: \|) so a cell
 * can never break the frame. Returns a malloc'd string. */
static char *escape_bars(const char *s, const char *repl) {
	size_t rl = strlen(repl), n = 0;
	for (const char *p = s; *p; p++) n += (*p == '|') ? rl : 1;
	char *out = malloc(n + 1);
	if (!out) return NULL;
	char *w = out;
	for (const char *p = s; *p; p++) {
		if (*p == '|') { memcpy(w, repl, rl); w += rl; }
		else *w++ = *p;
	}
	*w = '\0';
	return out;
}

/* Prints one framed cell: text (optionally colored), then padding to width. */
static void put_cell(const lst_ctx *c, const char *text, size_t width, const char *ansi) {
	const cli_opts *o = c->o;
	int color = ansi && o->use_color && o->fmt == FMT_TABLE;
	if (color) fputs(ansi, stdout);
	fputs(text, stdout);
	if (color) fputs(ANSI_RESET, stdout);
	size_t cps = utf8_count((const unsigned char *)text, strlen(text));
	for (size_t i = cps; i < width; i++) fputc(' ', stdout);
}

static void table_border(const lst_ctx *c) {
	fputc(c->o->fmt == FMT_TABLE ? '+' : '|', stdout);
	for (int col = 0; col < COL_COUNT; col++) {
		if (!c->present[col]) continue;
		size_t w = c->width[col] ? c->width[col] : strlen(col_label[col]);
		for (size_t i = 0; i < w + 2; i++) fputc('-', stdout);
		fputc(c->o->fmt == FMT_TABLE ? '+' : '|', stdout);
	}
	fputc('\n', stdout);
}

/* One framed row; cells arrive already shaped for the format (escaped). */
static void framed_row(const lst_ctx *c, char *const cells[COL_COUNT]) {
	for (int col = 0; col < COL_COUNT; col++) {
		if (!c->present[col]) continue;
		fputs("| ", stdout);
		put_cell(c, cells[col], c->width[col], col == COL_NAME ? ANSI_NAME : col == COL_VALUE ? ANSI_VALUE : NULL);
		fputc(' ', stdout);
	}
	fputs("|\n", stdout);
}

static void header_row(lst_ctx *c) {
	char *cells[COL_COUNT] = {0};
	for (int col = 0; col < COL_COUNT; col++) {
		if (!c->present[col]) continue;
		cells[col] = fit_cell((const unsigned char *)col_label[col], strlen(col_label[col]), c->width[col], 0);
	}
	if (c->o->fmt == FMT_TABLE) table_border(c);
	framed_row(c, cells);
	table_border(c);
	for (int col = 0; col < COL_COUNT; col++) free(cells[col]);
}

/* CSV field per RFC 4180: quoted when it holds a comma, quote, CR or LF. */
static void csv_field(const unsigned char *s, size_t len) {
	int quote = 0;
	for (size_t i = 0; i < len; i++) {
		if (s[i] == ',' || s[i] == '"' || s[i] == '\n' || s[i] == '\r') { quote = 1; break; }
	}
	if (!quote) { fwrite(s, 1, len, stdout); return; }
	fputc('"', stdout);
	for (size_t i = 0; i < len; i++) {
		if (s[i] == '"') fputc('"', stdout);
		fputc(s[i], stdout);
	}
	fputc('"', stdout);
}

/* Prints a displayed value in TSV form, cut to o->max_width characters with
 * an ellipsis and the raw byte count when it does not fit. */
static void print_value_tsv(const cli_opts *o, const unsigned char *disp, size_t disp_len, size_t raw_len) {
	size_t shown = disp_len;
	int cut = 0;
	if (o->max_width > 0) {
		shown = utf8_prefix_bytes(disp, disp_len, o->max_width);
		cut = shown < disp_len;
	}
	if (o->use_color) fputs(ANSI_VALUE, stdout);
	fwrite(disp, 1, shown, stdout);
	if (o->use_color) fputs(ANSI_RESET, stdout);
	if (cut) fprintf(stdout, "\xe2\x80\xa6(%zu bytes)", raw_len);
}

static void emit_entry(lst_ctx *c, const char *path, size_t path_len, const unsigned char *name, size_t name_len) {
	const cli_opts *o = c->o;
	xs_buffer v = {0};
	value_disp vd = {0};
	if (o->values) {
		int st = xs_get(path, path_len, (const char *)name, name_len, &o->xs, &v);
		if (st != XS_OK) {
			warn_path(c, path, path_len, name, name_len, st);
			return;
		}
		vd = render_value(o, v.data, v.len);
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
				fprintf(stdout, ",\"%s\":", vd.type);
				json_string(stdout, vd.bytes, vd.len);
			}
			fputc('}', stdout);
		}
	} else if (o->fmt == FMT_TSV) {
		if (o->recurse) {
			fwrite(path, 1, path_len, stdout);
			fputc('\t', stdout);
		}
		if (o->use_color) fputs(ANSI_NAME, stdout);
		fwrite(name, 1, name_len, stdout);
		if (o->use_color) fputs(ANSI_RESET, stdout);
		if (o->values) {
			if (c->present[COL_TYPE]) fprintf(stdout, "\t%s", vd.type);
			fputc('\t', stdout);
			print_value_tsv(o, vd.bytes, vd.len, v.len);
		}
		fputc('\n', stdout);
	} else {
		/* Names go through printable-binary in the delimited formats so no
		 * delimiter (| , tabs, control chars) can appear in them. */
		pb_ffi_result_t npb = pb_encode((const char *)name, name_len, PB_ENCODE_NONE, NULL, 0);
		const unsigned char *nb = npb.error_code == 0 && npb.data ? (const unsigned char *)npb.data : name;
		size_t nl = npb.error_code == 0 && npb.data ? npb.len : name_len;
		if (o->fmt == FMT_CSV) {
			int first = 1;
			if (o->recurse) { csv_field((const unsigned char *)path, path_len); first = 0; }
			if (!first) fputc(',', stdout);
			csv_field(nb, nl);
			if (o->values) { fputc(',', stdout); csv_field(vd.bytes, vd.len); }
			fputc('\n', stdout);
		} else {
			const char *bar = o->fmt == FMT_TABLE ? "\xe2\x88\xa3" : "\\|";
			char *cells[COL_COUNT] = {0};
			char *fitted[COL_COUNT] = {0};
			fitted[COL_PATH] = c->present[COL_PATH] ? fit_cell((const unsigned char *)path, path_len, c->width[COL_PATH], 1) : NULL;
			fitted[COL_NAME] = fit_cell(nb, nl, c->width[COL_NAME], 0);
			fitted[COL_TYPE] = c->present[COL_TYPE] ? fit_cell((const unsigned char *)vd.type, strlen(vd.type), c->width[COL_TYPE], 0) : NULL;
			fitted[COL_VALUE] = c->present[COL_VALUE] ? fit_cell(vd.bytes, vd.len, c->width[COL_VALUE], 0) : NULL;
			for (int col = 0; col < COL_COUNT; col++) {
				if (fitted[col]) cells[col] = escape_bars(fitted[col], bar);
			}
			framed_row(c, cells);
			for (int col = 0; col < COL_COUNT; col++) { free(fitted[col]); free(cells[col]); }
		}
		if (npb.data) pb_free(npb.data, npb.len);
	}
	if (o->values) {
		free_value(&vd);
		xs_buffer_free(&v);
	}
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
	if (status != XS_OK) {
		warn_path(c, path, path_len, NULL, 0, status);
		return 0;
	}
	int st = list_one(c, path, path_len);
	/* An entry that cannot be found any more has nothing to list: a dangling
	 * symlink, or a file deleted between reading its directory and now
	 * (browser caches churn like this). That is the tree's state, not an
	 * error in the walk, so it is skipped without noise unless the user asked
	 * to see skips. The root is exempt: the caller named it. */
	if (st == XS_NOT_FOUND && depth > 0) {
		const char *why = kind == XS_KIND_SYMLINK ? "dangling_symlink" : "vanished";
		if (c->o->debug) {
			if (c->o->json) {
				fprintf(stderr, "{\"debug\":\"%s\",\"path\":", why);
				json_string(stderr, (const unsigned char *)path, path_len);
				fputs("}\n", stderr);
			} else {
				fprintf(stderr, PROG ": debug: %.*s: %s, skipped\n", (int)path_len, path,
					kind == XS_KIND_SYMLINK ? "dangling symlink" : "vanished during the walk");
			}
		}
		return 0;
	}
	if (st != XS_OK) warn_path(c, path, path_len, NULL, 0, st);
	return 0;
}

static int cmd_lst(cli_opts *o, const char *path) {
	o->use_color = resolve_color(o);
	lst_ctx c = { o, 1, 0, {0}, {0} };
	c.present[COL_PATH] = o->recurse;
	c.present[COL_NAME] = 1;
	c.present[COL_TYPE] = o->values && o->utf8 && o->fmt != FMT_CSV;
	c.present[COL_VALUE] = o->values;
	size_t k = 0;
	for (int col = 0; col < COL_COUNT; col++) {
		if (!c.present[col]) continue;
		c.width[col] = k < o->cols_n ? o->cols[k] : col_default_width[col];
		k++;
	}
	int framed = !o->json && (o->fmt == FMT_TABLE || o->fmt == FMT_MD);
	if (o->json) fputc('[', stdout);
	else if (framed) header_row(&c);
	else if (o->fmt == FMT_CSV) {
		int first = 1;
		for (int col = 0; col < COL_COUNT; col++) {
			if (!c.present[col]) continue;
			if (!first) fputc(',', stdout);
			fputs(col_label[col], stdout);
			first = 0;
		}
		fputc('\n', stdout);
	}
	int st;
	if (o->recurse) {
		st = xs_walk(path, strlen(path), o->depth_first ? XS_WALK_DEPTH_FIRST : XS_WALK_BREADTH_FIRST,
			o->max_depth, walk_cb, &c);
	} else {
		st = list_one(&c, path, strlen(path));
	}
	if (o->json) fputs("]\n", stdout);
	else if (framed && o->fmt == FMT_TABLE) table_border(&c);
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
	int cols_given = 0;
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
			if (strcmp(a, "--hex") == 0) { o.hex = 1; continue; }
			if (strcmp(a, "--utf8") == 0) { o.utf8 = 1; continue; }
			if (strcmp(a, "--tsv") == 0) { o.fmt = FMT_TSV; continue; }
			if (strcmp(a, "--csv") == 0) { o.fmt = FMT_CSV; continue; }
			if (strcmp(a, "--table") == 0) { o.fmt = FMT_TABLE; continue; }
			if (strcmp(a, "--md") == 0 || strcmp(a, "--markdown") == 0) { o.fmt = FMT_MD; continue; }
			if (strcmp(a, "--cols") == 0 || strcmp(a, "--columns") == 0 ||
			    strncmp(a, "--cols=", 7) == 0 || strncmp(a, "--columns=", 10) == 0) {
				const char *spec = strchr(a, '=');
				if (spec) spec++;
				else if (i + 1 < argc) spec = argv[++i];
				if (!spec || !*spec) { usage(stderr); return EXIT_USAGE; }
				o.cols_n = 0;
				while (*spec) {
					char *end = NULL;
					errno = 0;
					unsigned long long w = strtoull(spec, &end, 10);
					if (errno != 0 || end == spec || (*end != '\0' && *end != ',') || o.cols_n == MAX_COLS) {
						fprintf(stderr, PROG ": --cols needs up to %d comma-separated non-negative integers\n", MAX_COLS);
						usage(stderr);
						return EXIT_USAGE;
					}
					o.cols[o.cols_n++] = (size_t)w;
					spec = *end == ',' ? end + 1 : end;
				}
				cols_given = 1;
				continue;
			}
			if (strcmp(a, "-w") == 0 || strcmp(a, "--max-width") == 0 ||
			    strncmp(a, "-w=", 3) == 0 || strncmp(a, "--max-width=", 12) == 0) {
				const char *num = strchr(a, '=');
				if (num) num++;
				else if (i + 1 < argc) num = argv[++i];
				uint64_t w = 0;
				if (parse_u64(num, &w) != 0 || w > SIZE_MAX) {
					fprintf(stderr, PROG ": --max-width needs a non-negative integer\n");
					usage(stderr);
					return EXIT_USAGE;
				}
				o.max_width = (size_t)w;
				continue;
			}
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

	/* Explicit widths mean a framed table unless Markdown was asked for. */
	if (cols_given && o.fmt != FMT_MD && o.fmt != FMT_CSV) o.fmt = FMT_TABLE;

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
	if (strcmp(cmd, "lst") == 0 || strcmp(cmd, "list") == 0 || strcmp(cmd, "dump") == 0 || strcmp(cmd, "dmp") == 0) {
		if (nargs != 1) { usage(stderr); return EXIT_USAGE; }
		if (strcmp(cmd, "dump") == 0 || strcmp(cmd, "dmp") == 0) o.values = 1;
		return cmd_lst(&o, pos[1]);
	}
	if (strcmp(cmd, "limits") == 0 || strcmp(cmd, "lim") == 0) {
		if (nargs > 1) { usage(stderr); return EXIT_USAGE; }
		return cmd_limits(&o, nargs == 1 ? pos[1] : ".");
	}
	fprintf(stderr, PROG ": unknown command '%s'\n", cmd);
	usage(stderr);
	return EXIT_USAGE;
}
