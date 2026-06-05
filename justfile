binary := "atlantic-dns"
src     := "src/atlantic_dns.cr"

default: build

build:
    @echo "==> Building {{binary}}..."
    shards install
    crystal build {{src}} -o {{binary}}
    @echo "==> Done: {{binary}}"

build-release:
    @echo "==> Building {{binary}} (release)..."
    shards install
    crystal build {{src}} -o {{binary}} --release
    @echo "==> Done: {{binary}}"

test:
    @echo "==> Running Crystal specs..."
    crystal spec

lint:
    @echo "==> Running ameba..."
    ./bin/ameba src/

clean:
    rm -f {{binary}}
    rm -rf dist/
