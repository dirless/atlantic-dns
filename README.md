# atlantic-dns

CLI for managing DNS records on [Atlantic.net](https://www.atlantic.net/).

## Install

```sh
just install        # release build, strip, sudo install → /usr/local/bin/atlantic-dns
just build          # → ./atlantic-dns  (debug build, no sudo)
just docker-build   # → dist/atlantic-dns  (AL2023-compatible)
```

## Credentials

Either export environment variables:

```sh
export ATLANTICNET_ACCESS_KEY=...
export ATLANTICNET_PRIVATE_KEY=...
```

Or pass a KeepassXC database (entry name: `atlanticnet`, Username = access key, Password = private key):

```sh
--keepass-db ~/path/to/passwords.kdbx
```

## Usage

```sh
# Instances
atlantic-dns instances                        # list all
atlantic-dns instances --name staging         # filter by name → shows IP

# Zones
atlantic-dns zones
atlantic-dns zone-add staging.example.com
atlantic-dns zone-delete staging.example.com

# Records
atlantic-dns list   --zone staging.example.com
atlantic-dns add    --zone staging.example.com --type A    --host app.staging.example.com --data 1.2.3.4
atlantic-dns add    --zone staging.example.com --type MX   --host staging.example.com     --data mail.example.com --priority 10
atlantic-dns set    --zone staging.example.com --type A    --host app.staging.example.com --data 5.6.7.8   # upsert
atlantic-dns set    --zone example.com --set-a-record-for-instance-name staging  # upsert staging.example.com → instance IP
atlantic-dns delete --zone staging.example.com --type A    --host app.staging.example.com
atlantic-dns delete --zone staging.example.com --id 416215
```

Pass `--json` for machine-readable output, `--debug` to log the signed request URL.

## Build & test

```sh
shards install
just build
crystal spec
```
