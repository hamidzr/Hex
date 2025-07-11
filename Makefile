.PHONY: build install clean test help

# Default target
help:
	@echo "HexCLI - Command-line voice-to-text transcription"
	@echo ""
	@echo "Available targets:"
	@echo "  build     - Build the CLI executable"
	@echo "  install   - Install the CLI to /usr/local/bin"
	@echo "  clean     - Clean build artifacts"
	@echo "  test      - Run a test transcription"
	@echo "  help      - Show this help message"

# Build the CLI
build:
	@echo "Building HexCLI..."
	swift build -c release

# Install to system path
install: build
	@echo "Installing hex-cli to /usr/local/bin..."
	sudo cp .build/release/hex-cli /usr/local/bin/
	@echo "Installation complete! You can now use 'hex-cli' from anywhere."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf .build

# Test the CLI with a short recording
test: build
	@echo "Testing HexCLI with a 3-second recording..."
	.build/release/hex-cli --duration 3 --verbose

# Development build (debug)
dev:
	@echo "Building debug version..."
	swift build

# Run directly from source
run:
	@echo "Running HexCLI from source..."
	swift run hex-cli $(ARGS)

# Show available models
models: build
	@echo "Available Whisper models:"
	.build/release/hex-cli --list-models

# Show available audio devices
devices: build
	@echo "Available audio input devices:"
	.build/release/hex-cli --list-devices 