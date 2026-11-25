import XCTest
@testable import UCMRemote

final class ServerSetupTests: XCTestCase {
    private let ucmScript = "#!/bin/sh\necho 'UCM'\n"
    private let krl = KRLSettings(serverURL: "https://ucm.local:8443", caID: 3, apiKey: "ucm_ak_Abc-123_x",
                                  intervalMinutes: 15, curlPin: "sha256//abc+/=", certificateFingerprint: "AA:BB")

    private func ca(type: String = "user") throws -> SSHCA {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SSHCA.self, from: Data(#"{"id": 3, "descr": "Büro CA", "ca_type": "\#(type)"}"#.utf8))
    }

    private func assertNoPlaceholders(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let regex = try! NSRegularExpression(pattern: "__[A-Z0-9_]+__")
        // __PROGRAMDATA__ ist ein Token von OpenSSH für Windows, kein Platzhalter der App.
        let cleaned = text.replacingOccurrences(of: "__PROGRAMDATA__", with: "")
        let m = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        XCTAssertNil(m, "Platzhalter übrig: \(m.map { (cleaned as NSString).substring(with: $0.range) } ?? "")", file: file, line: line)
    }

    func testShellQuote() {
        XCTAssertEqual(ServerSetup.shellQuote("a'b"), #"'a'\''b'"#)
        XCTAssertEqual(ServerSetup.psQuote("a'b\u{2019}c"), "'a''b\u{2019}\u{2019}c'")
    }

    func testLinuxScript() throws {
        let script = try ServerSetup.linuxScript(ucmScript: ucmScript, ca: ca(), principalsMode: .username,
                                                 principals: "root: it's", krl: krl)
        assertNoPlaceholders(script)
        XCTAssertTrue(script.contains("echo 'UCM'\nUCM_CA_SCRIPT_EOF"))
        XCTAssertTrue(script.contains("UCM_API_KEY='ucm_ak_Abc-123_x'"))
        XCTAssertTrue(script.contains("UCM_PIN='sha256//abc+/='"))
        XCTAssertTrue(script.contains("KRL_ENABLED='1'"))
        XCTAssertTrue(script.contains(#"PRINCIPALS='root: it'\''s'"#))
        XCTAssertTrue(script.contains("# CA: B_ro CA"))

        let paste = try ServerSetup.linuxPasteCommand(script: script, sudo: true)
        XCTAssertTrue(paste.hasPrefix(" sudo sh -c "))
        XCTAssertTrue(paste.hasSuffix("\nUCM_REMOTE_EOF\n"))
        XCTAssertTrue(try ServerSetup.linuxPasteCommand(script: script, sudo: false).hasPrefix(" sh -c "))
    }

    func testLinuxScriptWithoutKRLHasNoKey() throws {
        let script = try ServerSetup.linuxScript(ucmScript: ucmScript, ca: ca(), principalsMode: .keep, principals: "", krl: nil)
        assertNoPlaceholders(script)
        XCTAssertTrue(script.contains("KRL_ENABLED='0'"))
        XCTAssertTrue(script.contains("UCM_API_KEY=''"))
    }

    func testHostCAIgnoresKRLAndPrincipals() throws {
        let script = try ServerSetup.linuxScript(ucmScript: ucmScript, ca: ca(type: "host"), principalsMode: .username,
                                                 principals: "", krl: krl)
        XCTAssertTrue(script.contains("KRL_ENABLED='0'"))
        XCTAssertTrue(script.contains("PRINCIPALS_MODE='keep'"))
    }

    func testRejectsTerminatorInUCMScript() throws {
        XCTAssertThrowsError(try ServerSetup.linuxScript(ucmScript: "x\nUCM_CA_SCRIPT_EOF\n", ca: ca(),
                                                         principalsMode: .keep, principals: "", krl: nil))
        XCTAssertThrowsError(try ServerSetup.linuxPasteCommand(script: "a\nUCM_REMOTE_EOF\nb", sudo: true))
    }

    func testRejectsUnsafeKRLValues() throws {
        var bad = krl
        bad.apiKey = "ucm_ak_x'; echo injected"
        XCTAssertThrowsError(try ServerSetup.linuxScript(ucmScript: ucmScript, ca: ca(), principalsMode: .keep,
                                                         principals: "", krl: bad))
        bad = krl
        bad.serverURL = "http://ucm.local"
        XCTAssertThrowsError(try ServerSetup.windowsScript(ucmScript: ucmScript, ca: ca(), principalsMode: .keep,
                                                           principals: "", krl: bad))
    }

    func testWindowsScript() throws {
        let ucm = "$x = @'\nmulti\n'@\nWrite-Host 'Grüße'\n"
        let script = try ServerSetup.windowsScript(ucmScript: ucm, ca: ca(), principalsMode: .file,
                                                   principals: "marc: marc, admin", krl: krl)
        assertNoPlaceholders(script)
        XCTAssertTrue(script.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertTrue(script.contains("$UcmScriptB64   = '\(Data(ucm.utf8).base64EncodedString())'"))
        XCTAssertTrue(script.contains("apiKey  = 'ucm_ak_Abc-123_x'"))
        XCTAssertTrue(script.contains("pin     = 'AA:BB'"))
        let paste = try ServerSetup.windowsPasteCommand(script: script)
        XCTAssertTrue(paste.hasPrefix("$ucmSetup = @'\n"))
        XCTAssertTrue(paste.contains("\n'@\n$ucmFile"))
    }

    func testRemovalScripts() throws {
        XCTAssertTrue(try ServerSetup.removalScript(platform: .linux).contains("ucm-krl-update"))
        XCTAssertTrue(try ServerSetup.removalScript(platform: .windows).contains("UCM Remote KRL Update"))
    }
}
