.PHONY: build install clean test check help daemon daemon-stop

# Default target
help:
	@echo "HexCLI - Command-line voice-to-text transcription"
	@echo ""
	@echo "Available targets:"
	@echo "  build        - Build the CLI executable (release)"
	@echo "  dev          - Build debug version"
	@echo "  install      - Install the CLI to /usr/local/bin"
	@echo "  clean        - Clean build artifacts"
	@echo "  check        - Run unit and integration tests"
	@echo "  test         - Run a test transcription (3s recording)"
	@echo "  daemon       - Start the daemon (foreground)"
	@echo "  daemon-stop  - Stop a running daemon"
	@echo "  models       - List available Whisper models"
	@echo "  devices      - List audio input devices"
	@echo "  help         - Show this help message"

# Build the CLI
build:
	@echo "Building HexCLI..."
	swift build -c release

# Install to system path
install: build
	@echo "Installing hex-cli to /usr/local/bin..."
	cp .build/release/hex-cli ~/.local/bin/
	@echo "Installation complete! You can now use 'hex-cli' from anywhere."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf .build

# Run unit and integration tests
check:
	@echo "Running tests..."
	swift test

# Test the CLI with a short recording
test: build
	@echo "Testing HexCLI with a 3-second recording..."
	.build/release/hex-cli record --duration 3 --verbose

# Development build (debug)
dev:
	@echo "Building debug version..."
	swift build

# Run directly from source
run:
	@echo "Running HexCLI from source..."
	swift run hex-cli $(ARGS)

# Start daemon in foreground
daemon: build
	.build/release/hex-cli daemon --preload openai_whisper-tiny.en --preload distil-whisper_distil-large-v3_turbo

# Stop a running daemon
daemon-stop:
	@echo "Stopping hex daemon..."
	@rm -f /tmp/$$(whoami)/hex-daemon.sock
	@pkill -f "hex-cli daemon" 2>/dev/null || echo "No daemon running"

# Show available models
models: build
	@echo "Available Whisper models:"
	.build/release/hex-cli record --list-models

# Show available audio devices
devices: build
	@echo "Available audio input devices:"
	.build/release/hex-cli record --list-devices
