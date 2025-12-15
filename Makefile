.PHONY: native ape clean test

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror

native:
	$(CC) $(CFLAGS) -o bin/xattr_stream src/xattr_stream.c

ape:
	@if [ "$$(uname -s)" != "Linux" ] || [ "$$(uname -m)" != "x86_64" ]; then \
		echo "Error: APE build requires Linux x86_64 host." >&2; \
		exit 1; \
	fi
	@command -v cosmocc >/dev/null 2>&1 || { echo "Error: cosmocc not found on PATH." >&2; exit 1; }
	cosmocc -O2 -DNDEBUG -o bin/xattr_stream_ape.com src/xattr_stream.c

test:
	./test

clean:
	rm -f bin/xattr_stream bin/xattr_stream_ape.com

