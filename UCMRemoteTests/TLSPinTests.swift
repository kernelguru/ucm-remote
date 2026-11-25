import XCTest
@testable import UCMRemote

final class TLSPinTests: XCTestCase {
    /// Selbstsigniertes EC-Zertifikat (P-256). Erwartete Werte mit OpenSSL berechnet:
    /// openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
    private let der = Data(base64Encoded: "MIIBejCCAR+gAwIBAgIUGEWE+0LAq765qAhPI0exoLCgJb8wCgYIKoZIzj0EAwIwEjEQMA4GA1UEAwwHZWMudGVzdDAeFw0yNjExMjUxOTE1MjhaFw0yNjExMjcxOTE1MjhaMBIxEDAOBgNVBAMMB2VjLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS9UmkzNMPUdrc9axH/ee//uuhSiA7C+CmTxHDv0gz2zpi+Y0Qs/VcSE6tIDSpzpB6B+W2uhDhaYLL/V6Q6j9aIo1MwUTAdBgNVHQ4EFgQUQlgkVF4sRkeYMr8CFXblWmUIG+YwHwYDVR0jBBgwFoAUQlgkVF4sRkeYMr8CFXblWmUIG+YwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAxDObZ7Kea902fz12A5l7JmCOLDnp7EKGPoKN1vR4cgQCIQCUVavh3AL8imMDbU3+tinPug1bVRnfRWK9ma0JLSRoJw==")!

    func testCurlPublicKeyPin() {
        XCTAssertEqual(TLSPin.curlPublicKeyPin(der: der), "sha256//TqXSl8ar7S6yFzSa3yEZyyNQ/jzdpsai3LzLXeMD4LU=")
    }

    func testCertificateFingerprint() {
        XCTAssertEqual(TLSPin.certificateFingerprint(der: der), "42:B3:06:43:43:DD:E6:BD:A3:AB:FF:0C:A0:38:DD:96:CF:51:9C:AF:64:CD:41:49:68:A7:F0:68:A9:C5:AA:93")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(TLSPin.curlPublicKeyPin(der: Data([0x30, 0x82, 0xFF])))
        XCTAssertNil(TLSPin.curlPublicKeyPin(der: Data()))
    }
}
