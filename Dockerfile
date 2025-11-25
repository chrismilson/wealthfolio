# Global build args
ARG RUST_IMAGE=docker.io/rust:1.86-alpine

# Stage 1: build frontend
FROM \
    # Use the native runner (fast)
    --platform=$BUILDPLATFORM \
    docker.io/node:20-alpine \
    AS frontend
WORKDIR /app

ENV CI=1
COPY --exclude=addons --parents **/package.json .
COPY pnpm-lock.yaml pnpm-workspace.yaml .
# RUN find .; exit 1
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.node \
    npm install -g pnpm@9.9.0 && \
    pnpm install --frozen-lockfile

COPY \
    --exclude=src-core \
    --exclude=src-server \
    --exclude=src-tauri \
    --exclude=addons \
    . .

RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.node \
    # Build only the main app to avoid building workspace addons in this image
    pnpm tsc && \
    pnpm vite build && \
    mv dist /web-dist

# Stage 2: build server with cross-compilation
FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS backend

ARG TARGETPLATFORM
ARG CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
ARG OPENSSL_STATIC=1

# For handling cross-compilation
COPY --from=docker.io/tonistiigi/xx / /
WORKDIR /app

RUN --mount=type=cache,target=/var/cache/apk \
    # Install build tools for the HOST (to run cargo, build scripts)
    # clang/lld are needed for cross-linking
    # pkgconfig is required for openssl-sys to find the target libraries
    apk add --no-cache clang lld build-base git file pkgconfig && \
    # Install TARGET dependencies
    # xx-apk installs into /$(xx-info triple)/...
    xx-apk add --no-cache musl-dev gcc openssl-dev openssl-libs-static sqlite-dev

# Install rust target
RUN rustup target add $(xx-cargo --print-target-triple)

COPY --parents src-server src-core .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/app/src-server/target \
    xx-cargo fetch --manifest-path src-server/Cargo.toml && \
    xx-cargo build --release --manifest-path src-server/Cargo.toml && \
    # Move the binary to a predictable location because the target dir changes with --target
    cp src-server/target/$(xx-cargo --print-target-triple)/release/wealthfolio-server /wealthfolio-server

# Final Image
FROM docker.io/alpine:3.19
WORKDIR /app
# Copy from backend (which is now build platform, but binary is target platform)
COPY --from=backend /wealthfolio-server /usr/local/bin/wealthfolio-server
COPY --from=frontend /web-dist ./dist

# Sensible defaults for running the application
ENV WF_DB_PATH=/data/wealthfolio.db
VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/wealthfolio-server"]
