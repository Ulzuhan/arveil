.PHONY: build test lint fmt docs-serve docs-build clean

build:
	cd relay && go build -o bin/arveil-relay ./cmd/arveil-relay
	cd core && cargo build --workspace

test:
	cd relay && go test ./...
	cd core && cargo test --workspace

lint:
	cd relay && go vet ./...
	cd core && cargo fmt --all -- --check
	cd core && cargo clippy --workspace --all-targets -- -D warnings

fmt:
	cd relay && gofmt -w .
	cd core && cargo fmt --all

docs-serve:
	uvx --with "mkdocs-material~=9.7" mkdocs serve

docs-build:
	uvx --with "mkdocs-material~=9.7" mkdocs build --strict

clean:
	rm -rf relay/bin core/target site
