import ArgumentParser

struct HexCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hex-cli",
        abstract: "Command-line voice-to-text transcription using Whisper",
        version: "2.0.0",
        subcommands: [RecordCommand.self, TranscribeCommand.self, DaemonCommand.self],
        defaultSubcommand: RecordCommand.self
    )
}

HexCLI.main()
