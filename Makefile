SHELL   := /bin/bash
BINARY  := atlantic-dns
SRC     := src/atlantic_dns.cr

.PHONY: all build build-release clean test lint

all: build

build:
	@echo "==> Building $(BINARY)..."
	shards install
	crystal build $(SRC) -o $(BINARY)
	@echo "==> Done: $(BINARY)"

build-release:
	@echo "==> Building $(BINARY) (release)..."
	shards install
	crystal build $(SRC) -o $(BINARY) --release
	@echo "==> Done: $(BINARY)"

test:
	@echo "==> Running Crystal specs..."
	crystal spec

lint:
	@echo "==> Running ameba..."
	./bin/ameba src/

clean:
	rm -f $(BINARY)
	rm -rf dist/
