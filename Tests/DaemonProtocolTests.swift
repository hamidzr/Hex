import Foundation
import XCTest

@testable import HexCLI

final class DaemonProtocolTests: XCTestCase {

    // MARK: - Request encoding/decoding

    func testEncodeTranscribeRequest() throws {
        let request = DaemonRequest.transcribe(
            audio: "/tmp/test.wav", model: "openai_whisper-tiny.en", language: "en")
        let data = try DaemonWire.encode(request)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.hasSuffix("\n"), "wire format must be newline-terminated")
        XCTAssertTrue(str.contains("\"action\":\"transcribe\""))
        XCTAssertTrue(str.contains("/tmp/test.wav"))
        XCTAssertTrue(str.contains("openai_whisper-tiny.en"))
    }

    func testEncodeStatusRequest() throws {
        let request = DaemonRequest.status()
        let data = try DaemonWire.encode(request)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.contains("\"action\":\"status\""))
        // nil fields are omitted by JSONEncoder
        XCTAssertFalse(str.contains("\"audio\""))
        XCTAssertFalse(str.contains("\"model\""))
    }

    func testEncodePreloadRequest() throws {
        let request = DaemonRequest.preload(model: "openai_whisper-medium.en")
        let data = try DaemonWire.encode(request)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.contains("\"action\":\"preload\""))
        XCTAssertTrue(str.contains("\"model\":\"openai_whisper-medium.en\""))
    }

    func testRoundtripTranscribeRequest() throws {
        let original = DaemonRequest.transcribe(
            audio: "/path/to/audio.wav", model: "openai_whisper-tiny.en", language: "en")
        let data = try DaemonWire.encode(original)
        let decoded = try DaemonWire.decodeRequest(from: data)

        XCTAssertEqual(decoded.action, .transcribe)
        XCTAssertEqual(decoded.audio, "/path/to/audio.wav")
        XCTAssertEqual(decoded.model, "openai_whisper-tiny.en")
        XCTAssertEqual(decoded.language, "en")
    }

    func testRoundtripStatusRequest() throws {
        let original = DaemonRequest.status()
        let data = try DaemonWire.encode(original)
        let decoded = try DaemonWire.decodeRequest(from: data)

        XCTAssertEqual(decoded.action, .status)
        XCTAssertNil(decoded.audio)
        XCTAssertNil(decoded.model)
    }

    func testDecodeRequestWithoutTrailingNewline() throws {
        let json = """
            {"action":"transcribe","audio":"/tmp/f.wav","model":"tiny","language":"en"}
            """
        let data = json.data(using: .utf8)!
        let decoded = try DaemonWire.decodeRequest(from: data)

        XCTAssertEqual(decoded.action, .transcribe)
        XCTAssertEqual(decoded.audio, "/tmp/f.wav")
    }

    func testDecodeRequestWithCarriageReturn() throws {
        let json = """
            {"action":"status","audio":null,"model":null,"language":null}\r\n
            """
        let data = json.data(using: .utf8)!
        let decoded = try DaemonWire.decodeRequest(from: data)
        XCTAssertEqual(decoded.action, .status)
    }

    // MARK: - Response encoding/decoding

    func testEncodeSuccessResponse() throws {
        let response = DaemonResponse.success(text: "hello world", seconds: 1.23)
        let data = try DaemonWire.encode(response)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.hasSuffix("\n"))
        XCTAssertTrue(str.contains("\"ok\":true"))
        XCTAssertTrue(str.contains("\"text\":\"hello world\""))
        XCTAssertTrue(str.contains("\"seconds\":1.23"))
    }

    func testEncodeErrorResponse() throws {
        let response = DaemonResponse.error("file not found")
        let data = try DaemonWire.encode(response)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.contains("\"ok\":false"))
        XCTAssertTrue(str.contains("\"error\":\"file not found\""))
        // nil text is omitted by JSONEncoder
        XCTAssertFalse(str.contains("\"text\""))
    }

    func testEncodeStatusResponse() throws {
        let response = DaemonResponse.status(
            models: ["openai_whisper-tiny.en", "openai_whisper-medium.en"],
            loaded: "openai_whisper-tiny.en")
        let data = try DaemonWire.encode(response)
        let str = String(data: data, encoding: .utf8)!

        XCTAssertTrue(str.contains("\"ok\":true"))
        XCTAssertTrue(str.contains("openai_whisper-tiny.en"))
        XCTAssertTrue(str.contains("openai_whisper-medium.en"))
        XCTAssertTrue(str.contains("\"loaded\":\"openai_whisper-tiny.en\""))
    }

    func testRoundtripSuccessResponse() throws {
        let original = DaemonResponse.success(text: "test output", seconds: 2.5)
        let data = try DaemonWire.encode(original)
        let decoded = try DaemonWire.decodeResponse(from: data)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.text, "test output")
        XCTAssertEqual(decoded.seconds, 2.5)
        XCTAssertNil(decoded.error)
    }

    func testRoundtripErrorResponse() throws {
        let original = DaemonResponse.error("something went wrong")
        let data = try DaemonWire.encode(original)
        let decoded = try DaemonWire.decodeResponse(from: data)

        XCTAssertFalse(decoded.ok)
        XCTAssertNil(decoded.text)
        XCTAssertEqual(decoded.error, "something went wrong")
    }

    // MARK: - Edge cases

    func testDecodeInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try DaemonWire.decodeRequest(from: data))
    }

    func testDecodeEmptyData() {
        let data = Data()
        XCTAssertThrowsError(try DaemonWire.decodeRequest(from: data))
    }

    func testDecodeUnknownAction() {
        let json = """
            {"action":"unknown","audio":null,"model":null,"language":null}
            """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try DaemonWire.decodeRequest(from: data))
    }

    func testTranscriptionTextWithSpecialChars() throws {
        let text = "He said \"hello\" and she said 'goodbye'\nNew line here"
        let response = DaemonResponse.success(text: text, seconds: 0.5)
        let data = try DaemonWire.encode(response)
        let decoded = try DaemonWire.decodeResponse(from: data)
        XCTAssertEqual(decoded.text, text)
    }

    func testTranscriptionTextWithUnicode() throws {
        let text = "Bonjour le monde! Привет мир 你好世界"
        let response = DaemonResponse.success(text: text, seconds: 0.1)
        let data = try DaemonWire.encode(response)
        let decoded = try DaemonWire.decodeResponse(from: data)
        XCTAssertEqual(decoded.text, text)
    }

    // MARK: - Defaults

    func testDefaultSocketPathContainsUsername() {
        let path = DaemonDefaults.socketPath
        let user = ProcessInfo.processInfo.userName
        XCTAssertTrue(path.contains(user), "socket path should contain username")
        XCTAssertTrue(path.hasSuffix(".sock"), "socket path should end with .sock")
    }

    func testDefaultPreloadModels() {
        let models = DaemonDefaults.defaultPreload
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.contains("openai_whisper-tiny.en"))
        XCTAssertTrue(models.contains("distil-whisper_distil-large-v3_turbo"))
    }
}
