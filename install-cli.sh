#!/bin/bash

# HexCLI Installation Script
# This script builds and installs the HexCLI tool

set -e

echo "🎤 HexCLI Installation Script"
echo "=============================="

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This tool only works on macOS"
    exit 1
fi

# Check for Apple Silicon
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
    echo "❌ Error: This tool requires Apple Silicon (M1/M2/M3) Mac"
    echo "   Current architecture: $ARCH"
    exit 1
fi

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "❌ Error: Swift is not installed"
    echo "   Please install Xcode or Swift command line tools:"
    echo "   xcode-select --install"
    exit 1
fi

# Check macOS version
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo $MACOS_VERSION | cut -d. -f1)
MACOS_MINOR=$(echo $MACOS_VERSION | cut -d. -f2)

if [[ $MACOS_MAJOR -lt 13 ]]; then
    echo "❌ Error: macOS 13.0 or later is required"
    echo "   Current version: $MACOS_VERSION"
    exit 1
fi

echo "✅ System requirements met"
echo "   macOS: $MACOS_VERSION"
echo "   Architecture: $ARCH"
echo ""

# Build the CLI
echo "🔨 Building HexCLI..."
if ! swift build -c release; then
    echo "❌ Build failed"
    exit 1
fi

echo "✅ Build successful"

# Install to /usr/local/bin
echo "📦 Installing to /usr/local/bin..."

# Create /usr/local/bin if it doesn't exist
sudo mkdir -p /usr/local/bin

# Copy the executable
if sudo cp .build/release/hex-cli /usr/local/bin/; then
    echo "✅ Installation successful!"
else
    echo "❌ Installation failed"
    exit 1
fi

# Make sure it's executable
sudo chmod +x /usr/local/bin/hex-cli

# Verify installation
if command -v hex-cli &> /dev/null; then
    echo "✅ hex-cli is now available in your PATH"
    echo ""
    echo "🎉 Installation complete!"
    echo ""
    echo "Quick start:"
    echo "  hex-cli --help                    # Show help"
    echo "  hex-cli --list-devices           # List audio devices"
    echo "  hex-cli --list-models            # List available models"
    echo "  hex-cli --duration 5             # Record for 5 seconds"
    echo ""
    echo "The first time you use hex-cli, it will download and compile"
    echo "the Whisper model, which may take a few minutes."
    echo ""
    echo "For more information, see CLI-README.md"
else
    echo "❌ Installation verification failed"
    echo "   hex-cli is not in your PATH"
    exit 1
fi 