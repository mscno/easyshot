# syntax=docker/dockerfile:1
FROM rust:1-bookworm AS build
# aws-lc-sys needs cmake.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Build dependencies first so source-only changes reuse the cached layer.
COPY Cargo.toml Cargo.lock build.rs ./
RUN mkdir -p src migrations && echo 'fn main() {}' > src/main.rs && touch src/lib.rs \
    && cargo build --release --locked; rm -rf src
# Migrations and static assets are compiled into the binary.
COPY migrations ./migrations
COPY static ./static
COPY src ./src
RUN touch build.rs src/main.rs src/lib.rs && cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 shotglass
COPY --from=build /app/target/release/shotglass-server /usr/local/bin/shotglass-server
USER shotglass
ENV BIND_ADDR=0.0.0.0:8080 RUST_LOG=info
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/shotglass-server"]
