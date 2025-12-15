#include <stdio.h>
#include <string.h>

static void usage(FILE *out) {
	fprintf(out,
		"Usage:\n"
		"  xattr_stream --help\n"
		"  xattr_stream put <path> <xattr_name>\n"
		"  xattr_stream get <path> <xattr_name>\n"
		"  xattr_stream len <path> <xattr_name>\n"
		"  xattr_stream del <path> <xattr_name>\n"
		"  xattr_stream lst <path>\n"
	);
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "--help") == 0) {
		usage(stdout);
		return 0;
	}

	usage(stderr);
	return 2;
}

