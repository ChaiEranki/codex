#!/bin/bash

# Script to build codex binaries for all platforms with macOS notarization support.
# Mimics the GitHub workflow rust-release.yml for local builds with enhanced macOS support.

set -euo pipefail

# Directory of this script
SCRIPT_DIR=$(dirname "$0")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")
CODEX_RS_DIR="$REPO_ROOT/codex-rs"
DIST_DIR="$REPO_ROOT/dist/binaries"

echo "$SCRIPT_DIR"

# macOS notarization configuration
APPLE_CERTIFICATE_P12="${APPLE_CERTIFICATE_P12:-}"
APPLE_CERTIFICATE_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"
APPLE_NOTARIZATION_KEY_P8="${APPLE_NOTARIZATION_KEY_P8:-}"
APPLE_NOTARIZATION_KEY_ID="${APPLE_NOTARIZATION_KEY_ID:-}"
APPLE_NOTARIZATION_ISSUER_ID="${APPLE_NOTARIZATION_ISSUER_ID:-}"

# Ensure we're in the right place
echo "Building in $CODEX_RS_DIR"
cd "$CODEX_RS_DIR"

# Check if we're on macOS for notarization
IS_MACOS=false
if [[ "$OSTYPE" == "darwin"* ]]; then
    IS_MACOS=true
    echo "Detected macOS - will attempt notarization if credentials are provided"
fi

# Install specific Rust toolchain (matching CI)
echo "Installing Rust 1.80 toolchain (matching CI)..."
rustup toolchain install 1.80 --profile minimal
rustup default 1.80

# Install rustup targets (matching CI workflow)
echo "Ensuring all rustup targets are installed..."
rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin
rustup target add x86_64-unknown-linux-musl
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-musl
rustup target add aarch64-unknown-linux-gnu
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc

# Install cross for cross-compilation (better than manual Docker)
if ! command -v cross &> /dev/null; then
    echo "Installing cross for cross-compilation..."
    cargo install cross
else
    echo "cross is already installed"
fi

# Note about cross-compilation builds
if [[ "$IS_MACOS" == true ]]; then
    echo "Note: Cross-compilation targets will use Docker containers with proper toolchains."
    echo "Make sure Docker is running for non-macOS builds."
fi

# Define targets from the workflow
TARGETS=(
    "aarch64-apple-darwin"
    "x86_64-apple-darwin"
    "x86_64-unknown-linux-musl"
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-musl"
    "aarch64-unknown-linux-gnu"
    "x86_64-pc-windows-msvc"
    "aarch64-pc-windows-msvc"
)

BINS=(
    "codex"
    "codex-responses-api-proxy"
)

# Create dist directory
mkdir -p "$DIST_DIR"

# Function to setup macOS code signing
setup_macos_signing() {
    if [[ -z "$APPLE_CERTIFICATE_P12" || -z "$APPLE_CERTIFICATE_PASSWORD" ]]; then
        echo "Apple certificate credentials not provided. Skipping macOS signing."
        echo "To enable signing, set APPLE_CERTIFICATE_P12 and APPLE_CERTIFICATE_PASSWORD environment variables."
        return 1
    fi

    echo "Setting up macOS code signing..."

    local cert_path="${RUNNER_TEMP:-/tmp}/apple_signing_certificate.p12"
    local keychain_path="${RUNNER_TEMP:-/tmp}/codex-signing.keychain-db"
    local keychain_password="actions"

    # Decode certificate
    echo "$APPLE_CERTIFICATE_P12" | base64 -d > "$cert_path"

    # Create temporary keychain
    security create-keychain -p "$keychain_password" "$keychain_path"
    security set-keychain-settings -lut 21600 "$keychain_path"
    security unlock-keychain -p "$keychain_password" "$keychain_path"

    # Backup existing keychains
    local keychain_args=()
    while IFS= read -r keychain; do
        [[ -n "$keychain" ]] && keychain_args+=("$keychain")
    done < <(security list-keychains | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')

    # Add our keychain to the list
    if ((${#keychain_args[@]} > 0)); then
        security list-keychains -s "$keychain_path" "${keychain_args[@]}"
    else
        security list-keychains -s "$keychain_path"
    fi

    security default-keychain -s "$keychain_path"

    # Import certificate
    security import "$cert_path" -k "$keychain_path" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain_path" > /dev/null

    # Find signing identity
    local codesign_hashes=()
    while IFS= read -r hash; do
        [[ -n "$hash" ]] && codesign_hashes+=("$hash")
    done < <(security find-identity -v -p codesigning "$keychain_path" \
        | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' \
        | sort -u)

    if ((${#codesign_hashes[@]} == 0)); then
        echo "No signing identities found"
        cleanup_macos_signing
        return 1
    fi

    if ((${#codesign_hashes[@]} > 1)); then
        echo "Multiple signing identities found:"
        printf '  %s\n' "${codesign_hashes[@]}"
        cleanup_macos_signing
        return 1
    fi

    APPLE_CODESIGN_IDENTITY="${codesign_hashes[0]}"
    APPLE_CODESIGN_KEYCHAIN="$keychain_path"

    # Cleanup cert file
    rm -f "$cert_path"

    echo "macOS signing setup complete"
    return 0
}

# Function to cleanup macOS signing keychain
cleanup_macos_signing() {
    if [[ -n "${APPLE_CODESIGN_KEYCHAIN:-}" && -f "$APPLE_CODESIGN_KEYCHAIN" ]]; then
        echo "Cleaning up macOS signing keychain..."

        # Remove our keychain from the list
        local keychain_args=()
        while IFS= read -r keychain; do
            [[ "$keychain" == "$APPLE_CODESIGN_KEYCHAIN" ]] && continue
            [[ -n "$keychain" ]] && keychain_args+=("$keychain")
        done < <(security list-keychains | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')

        if ((${#keychain_args[@]} > 0)); then
            security list-keychains -s "${keychain_args[@]}"
            security default-keychain -s "${keychain_args[0]}"
        fi

        security delete-keychain "$APPLE_CODESIGN_KEYCHAIN"
    fi
}

# Function to sign macOS binaries
sign_macos_binary() {
    local binary_path="$1"

    if [[ -z "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
        echo "No signing identity available for $binary_path"
        return 1
    fi

    echo "Signing $binary_path..."
    local keychain_args=()
    if [[ -n "${APPLE_CODESIGN_KEYCHAIN:-}" && -f "$APPLE_CODESIGN_KEYCHAIN" ]]; then
        keychain_args+=(--keychain "${APPLE_CODESIGN_KEYCHAIN}")
    fi

    codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" "${keychain_args[@]}" "$binary_path"
}

# Function to notarize macOS binary
notarize_macos_binary() {
    local binary_path="$1"
    local binary_name="$2"

    if [[ -z "$APPLE_NOTARIZATION_KEY_P8" || -z "$APPLE_NOTARIZATION_KEY_ID" || -z "$APPLE_NOTARIZATION_ISSUER_ID" ]]; then
        echo "Apple notarization credentials not provided. Skipping notarization for $binary_name."
        echo "To enable notarization, set APPLE_NOTARIZATION_KEY_P8, APPLE_NOTARIZATION_KEY_ID, and APPLE_NOTARIZATION_ISSUER_ID environment variables."
        return 0
    fi

    echo "Notarizing $binary_name..."

    local notary_key_path="${RUNNER_TEMP:-/tmp}/notarytool.key.p8"
    echo "$APPLE_NOTARIZATION_KEY_P8" | base64 -d > "$notary_key_path"

    local archive_path="${RUNNER_TEMP:-/tmp}/${binary_name}.zip"
    rm -f "$archive_path"

    # Create zip archive
    ditto -c -k --keepParent "$binary_path" "$archive_path"

    # Submit for notarization
    local submission_json
    submission_json=$(xcrun notarytool submit "$archive_path" \
        --key "$notary_key_path" \
        --key-id "$APPLE_NOTARIZATION_KEY_ID" \
        --issuer "$APPLE_NOTARIZATION_ISSUER_ID" \
        --output-format json \
        --wait)

    local status
    status=$(printf '%s\n' "$submission_json" | jq -r '.status // "Unknown"')
    local submission_id
    submission_id=$(printf '%s\n' "$submission_json" | jq -r '.id // ""')

    echo "Notarization submission $submission_id completed with status $status"

    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization failed for ${binary_name} (submission ${submission_id}, status ${status})"
        rm -f "$notary_key_path" "$archive_path"
        return 1
    fi

    # Staple the notarization ticket
    echo "Stapling notarization ticket to $binary_path..."
    xcrun stapler staple "$binary_path"

    rm -f "$notary_key_path" "$archive_path"
}

# Setup macOS signing if on macOS
SIGNING_ENABLED=false
if [[ "$IS_MACOS" == true ]]; then
    if setup_macos_signing; then
        SIGNING_ENABLED=true
        trap cleanup_macos_signing EXIT
    fi
fi

# Function to check if Docker is available
check_docker() {
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to build targets using Docker directly
build_with_docker() {
    local target="$1"
    echo "Building $target using Docker..."

    if ! check_docker; then
        echo "❌ Docker is required for cross builds but not available"
        return 1
    fi

    # Use Docker directly with a Rust container that has the right toolchain
    local docker_image="rust:1.80-slim"

    # Configure build environment based on target
    local build_env=""
    if [[ "$target" == *musl* ]]; then
        # For MUSL targets, configure ring crate to avoid compiler issues
        build_env="CC=musl-gcc RUSTFLAGS='-C target-feature=-crt-static' RING_PREGENERATE_ASM=1"
    elif [[ "$target" == *linux-gnu* ]]; then
        # For GNU Linux targets, use cross compiler and configure OpenSSL
        if [[ "$target" == aarch64* ]]; then
            build_env="CC=aarch64-linux-gnu-gcc OPENSSL_DIR=/usr OPENSSL_NO_PKG_CONFIG=1 PKG_CONFIG_ALLOW_CROSS=1"
        else
            build_env="CC=x86_64-linux-gnu-gcc OPENSSL_DIR=/usr OPENSSL_NO_PKG_CONFIG=1 PKG_CONFIG_ALLOW_CROSS=1"
        fi
    fi

    # Run build in container
    if docker run --rm -v "$REPO_ROOT:/workspace" -w /workspace/codex-rs \
        -e CARGO_HOME=/workspace/.cargo \
        "$docker_image" \
        bash -c "
            apt-get update && apt-get install -y \
                build-essential pkg-config musl-tools musl-dev \
                gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
                gcc-x86-64-linux-gnu g++-x86-64-linux-gnu \
                clang llvm libssl-dev zlib1g-dev && \
            rustup target add $target && \
            $build_env cargo build --target $target --release --bin codex --bin codex-responses-api-proxy
        "; then

        # Copy binaries to dist directory
        for bin in "${BINS[@]}"; do
            src="$CODEX_RS_DIR/target/$target/release/$bin"
            if [[ "$target" == *windows* ]]; then
                src="$src.exe"
            fi
            dest="$DIST_DIR/$bin-$target"
            if [[ "$target" == *windows* ]]; then
                dest="$dest.exe"
            fi

            if [ -f "$src" ]; then
                cp "$src" "$dest"
                echo "✅ Copied $bin for $target"
            else
                echo "⚠️  Binary $src not found for $target"
            fi
        done
        return 0
    else
        echo "❌ Failed to build $target with Docker"
        return 1
    fi
}

# Categorize targets by build method
NATIVE_TARGETS=()
DOCKER_TARGETS=()
SKIP_MUSL="${SKIP_MUSL:-true}"  # Skip MUSL builds by default due to ring crate issues

for target in "${TARGETS[@]}"; do
    case "$target" in
        *apple-darwin*)
            # macOS targets - build natively on macOS
            if [[ "$IS_MACOS" == true ]]; then
                NATIVE_TARGETS+=("$target")
            else
                echo "⚠️  Skipping $target (requires macOS host)"
            fi
            ;;
        *pc-windows*)
            # Windows targets - cross-compilation from macOS often fails due to missing headers
            if [[ "$IS_MACOS" == true ]]; then
                echo "⚠️  Skipping $target (Windows cross-compilation from macOS requires complex setup)"
                DOCKER_TARGETS+=("$target")
            else
                NATIVE_TARGETS+=("$target")
            fi
            ;;
        *unknown-linux-musl*)
            # MUSL targets - problematic with ring crate in Docker
            if [[ "$SKIP_MUSL" == "true" ]]; then
                echo "⚠️  Skipping $target (MUSL builds have ring crate compatibility issues)"
                echo "    Set SKIP_MUSL=false to attempt MUSL builds anyway"
            else
                DOCKER_TARGETS+=("$target")
            fi
            ;;
        *unknown-linux-gnu*)
            # GNU Linux targets - generally work well
            DOCKER_TARGETS+=("$target")
            ;;
    esac
done

echo "📋 Build Plan:"
echo "  Native builds: ${NATIVE_TARGETS[*]:-none}"
echo "  Docker builds: ${DOCKER_TARGETS[*]:-none}"
echo ""

# Build native targets first
if ((${#NATIVE_TARGETS[@]} > 0)); then
    echo "🏗️  Building native targets: ${NATIVE_TARGETS[*]}"
    for target in "${NATIVE_TARGETS[@]}"; do
        echo "Building for $target..."

        if ! cargo build --target "$target" --release --bin codex --bin codex-responses-api-proxy; then
            echo "❌ Failed to build for $target"
            continue
        fi

        # Process binaries
        for bin in "${BINS[@]}"; do
            src="$CODEX_RS_DIR/target/$target/release/$bin"
            if [[ "$target" == *windows* ]]; then
                src="$src.exe"
            fi
            dest="$DIST_DIR/$bin-$target"
            if [[ "$target" == *windows* ]]; then
                dest="$dest.exe"
            fi

            cp "$src" "$dest"
            echo "✅ Copied $bin for $target to $dest"

            # Handle macOS signing and notarization
            if [[ "$target" == *apple-darwin* && "$SIGNING_ENABLED" == true ]]; then
                if sign_macos_binary "$dest"; then
                    notarize_macos_binary "$dest" "$bin-$target"
                fi
            fi
        done
    done
fi

# Build cross targets
if ((${#DOCKER_TARGETS[@]} > 0)); then
    echo ""
    echo "🔄 Building cross-compilation targets: ${DOCKER_TARGETS[*]}"
    for target in "${DOCKER_TARGETS[@]}"; do
        build_with_docker "$target"
    done
fi

cleanup_macos_signing

echo "All binaries built and copied to $DIST_DIR"
echo ""
echo "Build complete!"
echo ""
echo "To set up macOS signing and notarization for future builds, set these environment variables:"
echo "  export APPLE_CERTIFICATE_P12='base64-encoded-p12-certificate'"
echo "  export APPLE_CERTIFICATE_PASSWORD='certificate-password'"
echo "  export APPLE_NOTARIZATION_KEY_P8='base64-encoded-notarization-key'"
echo "  export APPLE_NOTARIZATION_KEY_ID='notarization-key-id'"
echo "  export APPLE_NOTARIZATION_ISSUER_ID='notarization-issuer-id'"
echo ""
echo "These credentials can be obtained from your Apple Developer account."
