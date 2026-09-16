/*
 * xattr_stream - C ABI for cross-platform binary-safe file attributes.
 *
 * Linux: user.* extended attributes.  macOS: extended attributes.
 * Windows: NTFS alternate data streams.  One name grammar, one error
 * taxonomy, byte-length payloads everywhere (never NUL-terminated strings).
 *
 * Ownership rules
 *   - Every pointer you pass in stays yours; the library never keeps it.
 *   - xs_get and xs_list fill an xs_buffer the library allocates. Release it
 *     with xs_buffer_free (never free()). xs_buffer_free on a zeroed or
 *     already-freed buffer is a no-op.
 *   - Strings returned by xs_status_name, xs_version and xs_target are
 *     static and must not be freed.
 *   - xs_last_os_error is thread-local; read it right after a failure.
 *
 * Thread safety: all functions are reentrant. Concurrent writers to the same
 * attribute serialize in the OS on POSIX (setxattr replaces atomically). On
 * Windows a stream write truncates then rewrites, so a concurrent reader can
 * observe a partial value; see README.
 *
 * MIT License. See LICENSE.
 */
#ifndef XATTR_STREAM_H
#define XATTR_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define XS_VERSION "0.2.0"

/*
 * Default bound on a single value, on every OS: the smallest OS ceiling
 * across targets (Linux XATTR_SIZE_MAX, 64 KiB), so a value accepted on one
 * platform is accepted on all. Raise it per call through xs_options only when
 * you knowingly target macOS or NTFS alone.
 */
#define XS_DEFAULT_MAX_VALUE_LEN 65536

/* Status codes. Values are frozen; new codes are only ever appended. */
typedef enum xs_status {
	XS_OK               = 0,
	XS_MISSING          = 1,  /* attribute does not exist on an existing path */
	XS_UNSUPPORTED      = 2,  /* filesystem/OS cannot hold attributes; NOT evidence of tampering */
	XS_READ_ONLY        = 3,  /* filesystem mounted read-only */
	XS_PERMISSION       = 4,  /* EACCES/EPERM/ACCESS_DENIED, including kernel policy refusals */
	XS_TOO_LARGE        = 5,  /* value exceeds OS, filesystem, or max_value_len bound */
	XS_NOT_FOUND        = 6,  /* the path itself does not exist */
	XS_INVALID_NAME     = 7,  /* name fails the logical-name policy or an OS limit */
	XS_INVALID_PATH     = 8,  /* path empty, too long, or contains NUL */
	XS_CHANGED          = 9,  /* value kept changing during read; bounded retries exhausted */
	XS_BUFFER_TOO_SMALL = 10, /* caller buffer smaller than the value or name */
	XS_OUT_OF_MEMORY    = 11,
	XS_IO               = 12, /* any other OS error; see xs_last_os_error */
	XS_INVALID_ARGUMENT = 13  /* NULL pointer with nonzero length, or NULL out-param */
} xs_status;

/*
 * Values up to this size fit every mainstream filesystem's default
 * configuration (ext4 without the ea_inode feature keeps all of an inode's
 * attributes in roughly one 4 KiB block). Advisory: the library does not
 * enforce it; the CLI warns above it.
 */
#define XS_PORTABLE_VALUE_LEN 4096

/* Why a name is unacceptable; see xs_validate_name. Values are frozen. */
typedef enum xs_name_rejection {
	XS_NAME_OK                     = 0,
	XS_NAME_EMPTY                  = 1,
	XS_NAME_TOO_LONG               = 2, /* over 127 bytes */
	XS_NAME_CONTROL_CHAR           = 3, /* < 0x20, 0x7f, or NUL */
	XS_NAME_FORBIDDEN_CHAR         = 4, /* one of / \ : * ? " < > | */
	XS_NAME_RESERVED               = 5, /* $..., com.apple..., Zone.Identifier */
	XS_NAME_NOT_UTF8               = 6,
	XS_NAME_EDGE_WHITESPACE_OR_DOT = 7, /* leading/trailing space, trailing dot */
	XS_NAME_LINUX_NAMESPACE        = 8, /* starts with user.; the library applies that itself on Linux */
	XS_NAME_INVALID_NATIVE         = 9  /* raw mode: hard OS limit or path character */
} xs_name_rejection;

/* Option flags, OR-ed into xs_options.flags. */
enum {
	XS_FLAG_NOFOLLOW  = 1u << 0, /* operate on a symlink itself, not its target */
	XS_FLAG_RAW_NAMES = 1u << 1  /* pass native names through, bypassing the logical grammar */
};

typedef struct xs_options {
	uint32_t flags;
	uint64_t max_value_len; /* 0 = XS_DEFAULT_MAX_VALUE_LEN. Bounds allocation on get and refuses larger sets. */
} xs_options;

/* Library-owned bytes. Release with xs_buffer_free. */
typedef struct xs_buffer {
	uint8_t *data; /* NULL when len == 0 */
	size_t len;
	size_t cap;
} xs_buffer;

/*
 * Logical names (default mode): 1..127 bytes of valid UTF-8, no control
 * characters, none of  / \ : * ? " < > |  , no leading/trailing space, no
 * trailing dot, not starting with '$' or 'com.apple.', not 'Zone.Identifier'
 * (case-insensitive), and not starting with 'user.' (Linux stores every
 * logical name as user.<name> itself, so a caller-supplied prefix would become
 * user.user.<name>). macOS and Windows store the name verbatim. Windows
 * stream names are case-insensitive: two logical names differing only in
 * case collide there.
 */

/* Create or replace the attribute value. */
xs_status xs_set(const char *path, size_t path_len,
                 const char *name, size_t name_len,
                 const void *value, size_t value_len,
                 const xs_options *opts);

/* Current value length. XS_MISSING when absent. */
xs_status xs_size(const char *path, size_t path_len,
                  const char *name, size_t name_len,
                  const xs_options *opts, uint64_t *out_len);

/* Read into a caller buffer; no allocation. XS_BUFFER_TOO_SMALL if it does not fit. */
xs_status xs_get_into(const char *path, size_t path_len,
                      const char *name, size_t name_len,
                      void *buf, size_t buf_cap,
                      const xs_options *opts, size_t *out_len);

/* Read the whole value into a library-allocated buffer (xs_buffer_free). */
xs_status xs_get(const char *path, size_t path_len,
                 const char *name, size_t name_len,
                 const xs_options *opts, xs_buffer *out);

/* Delete the attribute. XS_MISSING when it was not there. */
xs_status xs_remove(const char *path, size_t path_len,
                    const char *name, size_t name_len,
                    const xs_options *opts);

/*
 * List attribute names. out->data holds *out_count names, each terminated by
 * a NUL byte, back to back. Logical mode lists only names the logical grammar
 * can address; XS_FLAG_RAW_NAMES lists every native name.
 */
xs_status xs_list(const char *path, size_t path_len,
                  const xs_options *opts, xs_buffer *out, size_t *out_count);

void xs_buffer_free(xs_buffer *buf);

/* Best-effort maximum value size on the filesystem holding path, or -1 if unknown/unbounded. */
int64_t xs_limits(const char *path, size_t path_len);

/*
 * Native (OS-level) spelling of a logical name on this OS, NUL-terminated
 * into out. *out_len receives the length without the NUL even when the
 * buffer is too small.
 */
xs_status xs_native_name(const char *name, size_t name_len,
                         const xs_options *opts,
                         char *out, size_t out_cap, size_t *out_len);

/*
 * Why a name would be rejected under opts (XS_NAME_OK if acceptable). Pure,
 * touches no file. Call it after XS_INVALID_NAME to explain the refusal.
 */
int xs_validate_name(const char *name, size_t name_len, const xs_options *opts);
/* "XS_NAME_LINUX_NAMESPACE" etc.; "XS_NAME_UNKNOWN" outside the enum. Static. */
const char *xs_name_rejection_name(int rejection);
/* One-sentence human explanation of a rejection. Static. */
const char *xs_name_rejection_message(int rejection);

/* "XS_MISSING" etc.; "XS_UNKNOWN" for values outside the enum. Static. */
const char *xs_status_name(int status);

/* errno or Win32 error code behind the most recent failure on this thread. */
int32_t xs_last_os_error(void);

const char *xs_version(void); /* "0.2.0" */
const char *xs_target(void);  /* e.g. "x86_64-linux", "aarch64-macos", "x86_64-windows" */

#ifdef __cplusplus
}
#endif

#endif /* XATTR_STREAM_H */
