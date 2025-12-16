#if defined(__COSMOPOLITAN__) && !defined(_COSMO_SOURCE)
#define _COSMO_SOURCE 1
#endif

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__COSMOPOLITAN__)
#include <sys/types.h>
#include <libc/dce.h>
#include <libc/sysv/consts/nrlinux.h>
#define XATTR_NOFOLLOW 0x0001
#define XNU_SYSCALL_BASE 0x2000000
#define XNU_SYS_getxattr (XNU_SYSCALL_BASE + 234)
#define XNU_SYS_setxattr (XNU_SYSCALL_BASE + 236)
#define XNU_SYS_removexattr (XNU_SYSCALL_BASE + 238)
#define XNU_SYS_listxattr (XNU_SYSCALL_BASE + 240)
#elif defined(__APPLE__)
#include <sys/xattr.h>
#else
#include <sys/types.h>
#include <sys/xattr.h>
#if defined(__linux__)
#include <linux/limits.h>
#if defined(__has_include)
#if __has_include(<linux/xattr.h>)
#include <linux/xattr.h>
#endif
#else
#include <linux/xattr.h>
#endif
#endif
#endif

#define XATTR_STREAM_VERSION "0.0.0"

#if defined(__COSMOPOLITAN__) && defined(__x86_64__)
static long syscall_linux6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
	long ret;
	register long r10 __asm__("r10") = a4;
	register long r8 __asm__("r8") = a5;
	register long r9 __asm__("r9") = a6;
	asm volatile("syscall"
		     : "=a"(ret)
		     : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8), "r"(r9)
		     : "rcx", "r11", "memory");
	if (ret < 0 && ret > -4096) {
		errno = (int)(-ret);
		return -1;
	}
	return ret;
}

static long syscall_xnu6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
	long ret;
	unsigned char cf;
	long sysno = XNU_SYSCALL_BASE + n;
	register long r10 __asm__("r10") = a4;
	register long r8 __asm__("r8") = a5;
	register long r9 __asm__("r9") = a6;
	asm volatile("syscall\n\t"
		     "setc %1"
		     : "=a"(ret), "=qm"(cf)
		     : "a"(sysno), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8), "r"(r9)
		     : "rcx", "r11", "memory");
	if (cf) {
		errno = (int)ret;
		return -1;
	}
	return ret;
}
#endif

#if defined(__COSMOPOLITAN__) && defined(__aarch64__)
static long syscall_linux6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
	register long x0 __asm__("x0") = a1;
	register long x1 __asm__("x1") = a2;
	register long x2 __asm__("x2") = a3;
	register long x3 __asm__("x3") = a4;
	register long x4 __asm__("x4") = a5;
	register long x5 __asm__("x5") = a6;
	register long x8 __asm__("x8") = n;
	asm volatile("svc #0"
		     : "+r"(x0)
		     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
		     : "memory");
	if (x0 < 0 && x0 > -4096) {
		errno = (int)(-x0);
		return -1;
	}
	return x0;
}

static long syscall_xnu6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
	register long x0 __asm__("x0") = a1;
	register long x1 __asm__("x1") = a2;
	register long x2 __asm__("x2") = a3;
	register long x3 __asm__("x3") = a4;
	register long x4 __asm__("x4") = a5;
	register long x5 __asm__("x5") = a6;
	register long x16 __asm__("x16") = n;
	unsigned int cf;
	asm volatile("svc #0x80\n\t"
		     "cset %w1, cs"
		     : "+r"(x0), "=r"(cf)
		     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x16)
		     : "memory");
	if (cf) {
		errno = (int)x0;
		return -1;
	}
	return x0;
}
#endif

static const char *errno_name(int e) {
	switch (e) {
#ifdef ENOATTR
	case ENOATTR: return "ENOATTR";
#endif
#ifdef ENODATA
	case ENODATA: return "ENODATA";
#endif
#ifdef ENOTSUP
	case ENOTSUP: return "ENOTSUP";
#endif
#if defined(EOPNOTSUPP) && (!defined(ENOTSUP) || (EOPNOTSUPP != ENOTSUP))
	case EOPNOTSUPP: return "EOPNOTSUPP";
#endif
	case EACCES: return "EACCES";
	case EPERM: return "EPERM";
	case EINVAL: return "EINVAL";
	case ENOENT: return "ENOENT";
	case ENOMEM: return "ENOMEM";
	default: return "ERRNO";
	}
}

static int errno_is_missing_xattr(int e) {
	switch (e) {
#ifdef ENOATTR
	case ENOATTR:
		return 1;
#endif
#ifdef ENODATA
	case ENODATA:
		return 1;
#endif
	default:
		return 0;
	}
}

static int errno_is_xattr_notsup(int e) {
#ifdef ENOTSUP
	if (e == ENOTSUP) return 1;
#endif
#ifdef EOPNOTSUPP
	if (e == EOPNOTSUPP) return 1;
#endif
	return 0;
}

static void print_errno(const char *op, const char *path, const char *xname) {
	int e = errno;
	if (xname) {
		fprintf(stderr, "xattr_stream: %s: %s: %s: %s(%d): %s\n",
			op, path, xname, errno_name(e), e, strerror(e));
	} else {
		fprintf(stderr, "xattr_stream: %s: %s: %s(%d): %s\n",
			op, path, errno_name(e), e, strerror(e));
	}
}

static ssize_t xattr_get_size(const char *path, const char *xname, int nofollow) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return (ssize_t)syscall_linux6(__NR_linux_lgetxattr,
				(long)path, (long)xname, (long)NULL, 0, 0, 0);
		}
		return (ssize_t)syscall_linux6(__NR_linux_getxattr,
			(long)path, (long)xname, (long)NULL, 0, 0, 0);
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return (ssize_t)syscall_xnu6(234,
			(long)path, (long)xname, (long)NULL, 0, 0, opts);
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return getxattr(path, xname, NULL, 0, 0, opts);
#else
	if (nofollow) {
		return lgetxattr(path, xname, NULL, 0);
	}
	return getxattr(path, xname, NULL, 0);
#endif
}

static ssize_t xattr_get(const char *path, const char *xname, int nofollow, void *buf, size_t len) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return (ssize_t)syscall_linux6(__NR_linux_lgetxattr,
				(long)path, (long)xname, (long)buf, (long)len, 0, 0);
		}
		return (ssize_t)syscall_linux6(__NR_linux_getxattr,
			(long)path, (long)xname, (long)buf, (long)len, 0, 0);
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return (ssize_t)syscall_xnu6(234,
			(long)path, (long)xname, (long)buf, (long)len, 0, opts);
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return getxattr(path, xname, buf, len, 0, opts);
#else
	if (nofollow) {
		return lgetxattr(path, xname, buf, len);
	}
	return getxattr(path, xname, buf, len);
#endif
}

static int xattr_set(const char *path, const char *xname, int nofollow, const void *buf, size_t len) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return syscall_linux6(__NR_linux_lsetxattr,
				(long)path, (long)xname, (long)buf, (long)len, 0, 0) == -1 ? -1 : 0;
		} else {
			return syscall_linux6(__NR_linux_setxattr,
				(long)path, (long)xname, (long)buf, (long)len, 0, 0) == -1 ? -1 : 0;
		}
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return syscall_xnu6(236,
			(long)path, (long)xname, (long)buf, (long)len, 0, opts) == -1 ? -1 : 0;
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return setxattr(path, xname, buf, len, 0, opts);
#else
	if (nofollow) {
		return lsetxattr(path, xname, buf, len, 0);
	}
	return setxattr(path, xname, buf, len, 0);
#endif
}

static int xattr_del(const char *path, const char *xname, int nofollow) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return syscall_linux6(__NR_linux_lremovexattr,
				(long)path, (long)xname, 0, 0, 0, 0) == -1 ? -1 : 0;
		} else {
			return syscall_linux6(__NR_linux_removexattr,
				(long)path, (long)xname, 0, 0, 0, 0) == -1 ? -1 : 0;
		}
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return syscall_xnu6(238, (long)path, (long)xname, opts, 0, 0, 0) == -1 ? -1 : 0;
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return removexattr(path, xname, opts);
#else
	if (nofollow) {
		return lremovexattr(path, xname);
	}
	return removexattr(path, xname);
#endif
}

static ssize_t xattr_list_size(const char *path, int nofollow) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return (ssize_t)syscall_linux6(__NR_linux_llistxattr,
				(long)path, (long)NULL, 0, 0, 0, 0);
		}
		return (ssize_t)syscall_linux6(__NR_linux_listxattr,
			(long)path, (long)NULL, 0, 0, 0, 0);
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return (ssize_t)syscall_xnu6(240, (long)path, (long)NULL, 0, opts, 0, 0);
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return listxattr(path, NULL, 0, opts);
#else
	if (nofollow) {
		return llistxattr(path, NULL, 0);
	}
	return listxattr(path, NULL, 0);
#endif
}

static ssize_t xattr_list(const char *path, int nofollow, char *buf, size_t len) {
#if defined(__COSMOPOLITAN__)
	if (IsLinux()) {
		if (nofollow) {
			return (ssize_t)syscall_linux6(__NR_linux_llistxattr,
				(long)path, (long)buf, (long)len, 0, 0, 0);
		}
		return (ssize_t)syscall_linux6(__NR_linux_listxattr,
			(long)path, (long)buf, (long)len, 0, 0, 0);
	}
	if (IsXnu()) {
		int opts = nofollow ? XATTR_NOFOLLOW : 0;
		return (ssize_t)syscall_xnu6(240, (long)path, (long)buf, (long)len, opts, 0, 0);
	}
	errno = ENOSYS;
	return -1;
#elif defined(__APPLE__)
	int opts = nofollow ? XATTR_NOFOLLOW : 0;
	return listxattr(path, buf, len, opts);
#else
	if (nofollow) {
		return llistxattr(path, buf, len);
	}
	return listxattr(path, buf, len);
#endif
}

static int write_all(int fd, const void *buf, size_t len) {
	const unsigned char *p = (const unsigned char *)buf;
	size_t off = 0;
	while (off < len) {
		ssize_t n = write(fd, p + off, len - off);
		if (n < 0) {
			if (errno == EINTR) continue;
			return -1;
		}
		off += (size_t)n;
	}
	return 0;
}

static int read_all_stdin(unsigned char **out_buf, size_t *out_len) {
	enum { CHUNK = 64 * 1024 };
	size_t cap = CHUNK;
	size_t len = 0;
	unsigned char *buf = (unsigned char *)malloc(cap);
	if (!buf) return -1;

	for (;;) {
		if (len == cap) {
			size_t new_cap = cap * 2;
			if (new_cap < cap) {
				free(buf);
				errno = ENOMEM;
				return -1;
			}
			unsigned char *new_buf = (unsigned char *)realloc(buf, new_cap);
			if (!new_buf) {
				free(buf);
				return -1;
			}
			buf = new_buf;
			cap = new_cap;
		}

		ssize_t n = read(STDIN_FILENO, buf + len, cap - len);
		if (n < 0) {
			if (errno == EINTR) continue;
			free(buf);
			return -1;
		}
		if (n == 0) break;
		len += (size_t)n;
	}

	*out_buf = buf;
	*out_len = len;
	return 0;
}

static void usage(FILE *out) {
	fprintf(out,
		"Usage:\n"
		"  xattr_stream --help\n"
		"  xattr_stream --version\n"
		"  xattr_stream limits\n"
		"  xattr_stream [--nofollow] put <path> <xattr_name>\n"
		"  xattr_stream [--nofollow] get <path> <xattr_name>\n"
		"  xattr_stream [--nofollow] len <path> <xattr_name>\n"
		"  xattr_stream [--nofollow] del <path> <xattr_name>\n"
		"  xattr_stream [--nofollow] lst <path>\n"
		"\n"
		"Options:\n"
		"  --nofollow   operate on symlink itself\n"
	);
}

static int cmd_limits(void) {
	long long limit = -1;

#if defined(_PC_XATTR_SIZE_MAX)
	errno = 0;
	long pc = pathconf(".", _PC_XATTR_SIZE_MAX);
	if (pc > 0) {
		limit = (long long)pc;
		printf("%lld\n", limit);
		return 0;
	}
#endif

#if defined(__linux__) && defined(XATTR_SIZE_MAX)
	limit = (long long)XATTR_SIZE_MAX;
	printf("%lld\n", limit);
	return 0;
#endif

#if defined(__COSMOPOLITAN__)
	/* Probe-based fallback for APE on macOS where pathconf constants aren't available. */
	const char *path = ".";
	const char *xname = IsXnu() ? "com.openai.xattr_stream.limits" : "user.xattr_stream.limits";
	char tmpname[] = ".xattr_stream_limits_XXXXXX";
	int fd = mkstemp(tmpname);
	if (fd < 0) {
		print_errno("mkstemp", path, NULL);
		printf("-1\n");
		return 0;
	}
	close(fd);

	long long lo = 0;
	long long hi = 1024;
	unsigned char *buf = NULL;

	for (;;) {
		buf = (unsigned char *)malloc((size_t)hi);
		if (!buf) {
			break;
		}
		if (xattr_set(tmpname, xname, 0, buf, (size_t)hi) != 0) {
			free(buf);
			buf = NULL;
			break;
		}
		free(buf);
		buf = NULL;
		lo = hi;
		if (hi > (1LL << 30)) { /* cap probe at 1GiB to avoid runaway */
			break;
		}
		hi *= 2;
	}

	if (lo > 0 && hi > lo) {
		long long left = lo;
		long long right = hi;
		while (right - left > 1) {
			long long mid = left + (right - left) / 2;
			buf = (unsigned char *)malloc((size_t)mid);
			if (!buf) break;
			if (xattr_set(tmpname, xname, 0, buf, (size_t)mid) == 0) {
				left = mid;
			} else {
				right = mid;
			}
			free(buf);
			buf = NULL;
		}
		limit = left;
	}

	(void)xattr_del(tmpname, xname, 0);
	(void)unlink(tmpname);

	printf("%lld\n", limit);
	return 0;
#endif

	printf("%lld\n", limit);
	return 0;
}

int main(int argc, char **argv) {
	int nofollow = 0;
	int argi = 1;

	for (; argi < argc; argi++) {
		if (strcmp(argv[argi], "--nofollow") == 0) {
			nofollow = 1;
			continue;
		}
		if (strcmp(argv[argi], "--help") == 0) {
			usage(stdout);
			return 0;
		}
		if (strcmp(argv[argi], "--version") == 0) {
			printf("xattr_stream %s\n", XATTR_STREAM_VERSION);
			return 0;
		}
		if (strncmp(argv[argi], "--", 2) == 0) {
			usage(stderr);
			return 2;
		}
		break;
	}

	if (argi >= argc) {
		usage(stderr);
		return 2;
	}

	const char *cmd = argv[argi++];

	if (strcmp(cmd, "limits") == 0) {
		if (argi != argc) {
			usage(stderr);
			return 2;
		}
		return cmd_limits();
	}

	if (strcmp(cmd, "len") == 0) {
		if (argi + 2 != argc) {
			usage(stderr);
			return 2;
		}
		const char *path = argv[argi++];
		const char *xname = argv[argi++];

		ssize_t n = xattr_get_size(path, xname, nofollow);
		if (n < 0) {
			if (errno_is_missing_xattr(errno)) {
				printf("-1\n");
				return 0;
			}
			print_errno("getxattr", path, xname);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		printf("%" PRIdMAX "\n", (intmax_t)n);
		return 0;
	}

	if (strcmp(cmd, "put") == 0) {
		if (argi + 2 != argc) {
			usage(stderr);
			return 2;
		}
		const char *path = argv[argi++];
		const char *xname = argv[argi++];

		unsigned char *buf = NULL;
		size_t len = 0;
		if (read_all_stdin(&buf, &len) != 0) {
			print_errno("read", "<stdin>", NULL);
			return 1;
		}

		int rc = xattr_set(path, xname, nofollow, buf, len);
		free(buf);
		if (rc != 0) {
			print_errno("setxattr", path, xname);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		return 0;
	}

	if (strcmp(cmd, "get") == 0) {
		if (argi + 2 != argc) {
			usage(stderr);
			return 2;
		}
		const char *path = argv[argi++];
		const char *xname = argv[argi++];

		ssize_t n = xattr_get_size(path, xname, nofollow);
		if (n < 0) {
			print_errno("getxattr", path, xname);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		if (n == 0) {
			return 0;
		}
		if ((uintmax_t)n > (uintmax_t)SIZE_MAX) {
			fprintf(stderr, "xattr_stream: get: value too large\n");
			return 1;
		}

		size_t len = (size_t)n;
		void *buf = malloc(len);
		if (!buf) {
			print_errno("malloc", "<mem>", NULL);
			return 1;
		}
		ssize_t got = xattr_get(path, xname, nofollow, buf, len);
		if (got < 0) {
			free(buf);
			print_errno("getxattr", path, xname);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		if (write_all(STDOUT_FILENO, buf, (size_t)got) != 0) {
			free(buf);
			print_errno("write", "<stdout>", NULL);
			return 1;
		}
		free(buf);
		return 0;
	}

	if (strcmp(cmd, "del") == 0) {
		if (argi + 2 != argc) {
			usage(stderr);
			return 2;
		}
		const char *path = argv[argi++];
		const char *xname = argv[argi++];

		if (xattr_del(path, xname, nofollow) != 0) {
			if (errno_is_missing_xattr(errno)) {
				return 0;
			}
			print_errno("removexattr", path, xname);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		return 0;
	}

	if (strcmp(cmd, "lst") == 0) {
		if (argi + 1 != argc) {
			usage(stderr);
			return 2;
		}
		const char *path = argv[argi++];

		ssize_t n = xattr_list_size(path, nofollow);
		if (n < 0) {
			print_errno("listxattr", path, NULL);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}
		if (n == 0) {
			return 0;
		}
		if ((uintmax_t)n > (uintmax_t)SIZE_MAX) {
			fprintf(stderr, "xattr_stream: lst: list too large\n");
			return 1;
		}

		size_t len = (size_t)n;
		char *buf = (char *)malloc(len);
		if (!buf) {
			print_errno("malloc", "<mem>", NULL);
			return 1;
		}

		ssize_t got = xattr_list(path, nofollow, buf, len);
		if (got < 0) {
			free(buf);
			print_errno("listxattr", path, NULL);
			if (errno_is_xattr_notsup(errno)) {
				return 3;
			}
			return 1;
		}

		size_t i = 0;
		while (i < (size_t)got) {
			size_t start = i;
			while (i < (size_t)got && buf[i] != '\0') {
				i++;
			}
			if (i > start) {
				if (write_all(STDOUT_FILENO, buf + start, i - start) != 0) {
					free(buf);
					print_errno("write", "<stdout>", NULL);
					return 1;
				}
				if (write_all(STDOUT_FILENO, "\n", 1) != 0) {
					free(buf);
					print_errno("write", "<stdout>", NULL);
					return 1;
				}
			}
			i++;
		}

		free(buf);
		return 0;
	}

	usage(stderr);
	return 2;
}
