import Foundation
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct HomebrewUpdateCheckerTests {
  private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
    let name = "SSMVUpdateTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(defaults)
  }

  @Test func comparesNumericVersionsAndRejectsMalformedValues() {
    #expect(HomebrewUpdateChecker.isNewer("0.2.10", than: "0.2.9"))
    #expect(HomebrewUpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    #expect(!HomebrewUpdateChecker.isNewer("0.2.2", than: "0.2.2"))
    #expect(!HomebrewUpdateChecker.isNewer("0.2.1", than: "0.2.2"))
    for bad in ["1.2", "1.2.3.4", "1.2.-3", "1.2.3-beta", "1.02.3", "1.2.999999999999999999999999"]
    {
      #expect(!HomebrewUpdateChecker.isNewer(bad, than: "0.0.0"))
    }
  }

  @Test func acceptsOnlyOneLiteralVersion() {
    #expect(HomebrewUpdateChecker.version(in: Data("  version \"0.2.10\"\n".utf8)) == "0.2.10")
    for bad in [
      "version :latest", "# version \"9.0.0\"", "version \"1.2.3\"; system('bad')",
      "version \"1.2.3\"\nversion \"2.0.0\"",
    ] {
      #expect(HomebrewUpdateChecker.version(in: Data(bad.utf8)) == nil)
    }
    #expect(HomebrewUpdateChecker.version(in: Data(repeating: 65, count: 65_537)) == nil)
    #expect(HomebrewUpdateChecker.version(in: Data([0xFF])) == nil)
  }

  @Test func throttlesAcrossLaunchesAndSuppressesAnnouncedVersion() async {
    await withDefaults { defaults in
      var date = Date(timeIntervalSince1970: 1_000_000)
      var calls = 0
      var advertised = "0.2.10"
      let fetch = { () async throws -> Data in
        calls += 1
        return Data("version \"\(advertised)\"".utf8)
      }
      let checker = HomebrewUpdateChecker(
        currentVersion: "0.2.9", defaults: defaults, now: { date }, fetch: fetch)
      #expect(await checker.check() == "0.2.10")
      checker.markNotified("0.2.10")
      let relaunched = HomebrewUpdateChecker(
        currentVersion: "0.2.9", defaults: defaults, now: { date }, fetch: fetch)
      #expect(await relaunched.check() == nil)
      #expect(calls == 1)
      date.addTimeInterval(86_400)
      #expect(await relaunched.check() == nil)
      #expect(calls == 2)
      advertised = "0.3.0"
      date.addTimeInterval(86_400)
      #expect(await relaunched.check() == "0.3.0")
    }
  }

  @Test func failuresStaySilentAndAreThrottled() async {
    await withDefaults { defaults in
      var calls = 0
      let checker = HomebrewUpdateChecker(
        currentVersion: "0.2.2", defaults: defaults,
        fetch: {
          calls += 1
          throw URLError(.timedOut)
        })
      #expect(await checker.check() == nil)
      #expect(await checker.check() == nil)
      #expect(calls == 1)
    }
  }

  @Test func oversizedResponsesNeverAdvertiseUpdates() async {
    await withDefaults { defaults in
      let checker = HomebrewUpdateChecker(
        currentVersion: "0.2.2", defaults: defaults,
        fetch: {
          Data(("version \"9.0.0\"\n" + String(repeating: " ", count: 65_536)).utf8)
        })
      #expect(await checker.check() == nil)
    }
  }
}
