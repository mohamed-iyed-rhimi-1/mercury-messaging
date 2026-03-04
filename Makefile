.PHONY: dev test lint bench schema-gen clean stop

# Start all development dependencies
dev:
	docker compose up -d
	@echo "Waiting for services..."
	@sleep 5
	@docker compose ps

# Initialize databases (run after first `make dev`)
db-init:
	@echo "Initializing ScyllaDB..."
	docker compose exec -T scylladb cqlsh < infra/docker/scylla-init.cql
	@echo "ScyllaDB ready."

# Reset databases (destructive)
db-reset:
	docker compose down -v
	$(MAKE) dev
	@sleep 10
	$(MAKE) db-init

# Build Rust NIF and copy to Elixir priv
nif:
	cargo build --release -p mercury-nif
	mkdir -p apps/mercury_core/priv/native
	cp target/release/libmercury_nif.dylib apps/mercury_core/priv/native/libmercury_nif.so

# Run all tests (Rust + Elixir)
test: test-rust nif test-elixir

test-rust:
	cargo test --all-features

test-elixir:
	mix test

# Lint everything
lint: lint-rust lint-elixir lint-schema

lint-rust:
	cargo fmt --all -- --check
	cargo clippy --all-targets --all-features -- -D warnings

lint-elixir:
	mix format --check-formatted
	mix credo --strict

lint-schema:
	capnp compile -o- schema/mercury/v1/*.capnp

# Generate code from Cap'n Proto schemas
schema-gen:
	cargo build -p mercury-core 2>&1 | head -20
	@echo "Schema codegen complete (Rust)"

# Run benchmarks
bench:
	cargo bench --all-features

# Clean everything
clean:
	cargo clean
	mix clean
	docker compose down -v

# Stop dev services
stop:
	docker compose down
