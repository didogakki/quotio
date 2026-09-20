import Foundation
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class QuotaCacheClientTests: XCTestCase {
  func testFetchSendsOnlyAuthIndexAndBearerManagementKey() async throws {
    let envelope = """
      {"result":{"status_code":200,"header":{},"body":"{\\"ok\\":true}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}
      """
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data(envelope.utf8))
    let client = QuotaCacheClient(session: session)

    _ = try await client.fetch(
      baseURL: "https://cache.example.com/quota-cache/v1/plus",
      resource: "claude-usage",
      authIndex: "claude-a",
      managementKey: "admin-key"
    )

    let request = await session.lastRequest
    XCTAssertEqual(request?.httpMethod, "GET")
    XCTAssertEqual(request?.url?.path, "/quota-cache/v1/plus/claude-usage")
    XCTAssertEqual(
      request?.url?.query?.components(separatedBy: "&"), ["auth_index=claude-a"],
      "must never send an upstream URL/header/token — only auth_index identifies the account")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer admin-key")
  }

  func testFetchDecodesEnvelopeIntoProxyAPICallResultShape() async throws {
    let envelope = """
      {"result":{"status_code":429,"header":{"Retry-After":["120"]},"body":"rate limited"},"fetched_at":1700000000,"stale":true,"last_attempt":1700000500,"next_retry_at":1700000600}
      """
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data(envelope.utf8))
    let client = QuotaCacheClient(session: session)

    let response = try await client.fetch(
      baseURL: "https://cache.example.com/quota-cache/v1/plus",
      resource: "claude-usage",
      authIndex: "claude-a",
      managementKey: "admin-key"
    )

    XCTAssertEqual(response.result.statusCode, 429)
    XCTAssertEqual(response.result.header?["Retry-After"], ["120"])
    XCTAssertEqual(response.result.body, "rate limited")
    XCTAssertEqual(response.fetchedAt, 1_700_000_000)
    XCTAssertTrue(response.stale)
    XCTAssertEqual(response.nextRetryAt, 1_700_000_600)
  }

  func testFetchThrowsHTTPErrorOnNon200OuterStatus() async {
    let session = RecordingQuotaHTTPSession(statusCode: 503, body: Data())
    let client = QuotaCacheClient(session: session)

    do {
      _ = try await client.fetch(
        baseURL: "https://cache.example.com/quota-cache/v1/plus",
        resource: "claude-usage", authIndex: "claude-a", managementKey: "admin-key"
      )
      XCTFail("expected httpError")
    } catch QuotaCacheError.httpError(let code) {
      XCTAssertEqual(code, 503)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchThrowsInvalidResponseOnUnparsableEnvelope() async {
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data("not json".utf8))
    let client = QuotaCacheClient(session: session)

    do {
      _ = try await client.fetch(
        baseURL: "https://cache.example.com/quota-cache/v1/plus",
        resource: "claude-usage", authIndex: "claude-a", managementKey: "admin-key"
      )
      XCTFail("expected invalidResponse")
    } catch QuotaCacheError.invalidResponse {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchRejectsARelativeOrSchemelessBaseURL() async {
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data())
    let client = QuotaCacheClient(session: session)

    do {
      _ = try await client.fetch(baseURL: "not-a-url", resource: "claude-usage", authIndex: "a", managementKey: "k")
      XCTFail("expected invalidBaseURL")
    } catch QuotaCacheError.invalidBaseURL {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    let request = await session.lastRequest
    XCTAssertNil(request, "an invalid base URL must never reach the network")
  }

  func testFetchRejectsAnHTTPBaseURLOnANonLoopbackHost() async {
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data())
    let client = QuotaCacheClient(session: session)

    do {
      _ = try await client.fetch(
        baseURL: "http://cache.example.com/quota-cache/v1/plus", resource: "claude-usage",
        authIndex: "a", managementKey: "k")
      XCTFail("expected invalidBaseURL")
    } catch QuotaCacheError.invalidBaseURL {
      // expected: plaintext http is only ever trusted for loopback
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    let request = await session.lastRequest
    XCTAssertNil(request, "a non-loopback http base URL must never reach the network")
  }

  func testFetchAllowsAnHTTPBaseURLOnLoopback() async throws {
    let envelope = """
      {"result":{"status_code":200,"header":{},"body":"{}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}
      """
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data(envelope.utf8))
    let client = QuotaCacheClient(session: session)

    _ = try await client.fetch(
      baseURL: "http://127.0.0.1:8328/quota-cache/v1/plus", resource: "claude-usage",
      authIndex: "a", managementKey: "k")

    let request = await session.lastRequest
    XCTAssertNotNil(request)
  }

  func testFetchRejectsABaseURLCarryingUserinfoOrFragment() async {
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data())
    let client = QuotaCacheClient(session: session)

    for baseURL in [
      "https://user:pass@cache.example.com/quota-cache/v1/plus",
      "https://cache.example.com/quota-cache/v1/plus#frag",
    ] {
      do {
        _ = try await client.fetch(baseURL: baseURL, resource: "claude-usage", authIndex: "a", managementKey: "k")
        XCTFail("expected invalidBaseURL for \(baseURL)")
      } catch QuotaCacheError.invalidBaseURL {
        // expected
      } catch {
        XCTFail("unexpected error: \(error)")
      }
    }
    let request = await session.lastRequest
    XCTAssertNil(request, "a base URL with userinfo or a fragment must never reach the network")
  }

  func testFetchRejectsAnUnknownResource() async {
    let session = RecordingQuotaHTTPSession(statusCode: 200, body: Data())
    let client = QuotaCacheClient(session: session)

    do {
      _ = try await client.fetch(
        baseURL: "https://cache.example.com/quota-cache/v1/plus", resource: "not-a-real-resource",
        authIndex: "a", managementKey: "k")
      XCTFail("expected invalidBaseURL")
    } catch QuotaCacheError.invalidBaseURL {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    let request = await session.lastRequest
    XCTAssertNil(request, "an unknown resource must never reach the network")
  }
}

actor RecordingQuotaHTTPSession: QuotaHTTPSession {
  private let statusCode: Int
  private let body: Data
  private(set) var lastRequest: URLRequest?

  init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    let response = HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (body, response)
  }
}
