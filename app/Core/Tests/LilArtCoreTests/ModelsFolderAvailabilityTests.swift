import Foundation
import Testing
@testable import LilArtCore

@Suite struct ModelsFolderAvailabilityTests {
  @Test func anUnpluggedDiskIsNamedAndPromisesNothingIsFetchedAgain() throws {
    let folder = URL(fileURLWithPath: "/Volumes/T7/models")
    let message = try #require(ModelsFolder.unavailableMessage(folder, reachable: { _ in false }))
    #expect(message.contains("«T7»"))
    #expect(message.contains("не подключён"))
    #expect(message.contains("заново ничего не скачивается"))
  }

  @Test func aPluggedDiskNeedsNoMessage() {
    let folder = URL(fileURLWithPath: "/Volumes/T7/models")
    #expect(ModelsFolder.unavailableMessage(folder, reachable: { _ in true }) == nil)
  }

  @Test func aFolderOnTheMacIsNeverUnavailable() {
    let folder = URL(fileURLWithPath: "/Users/someone/AI dev/lil/lil-art/models")
    #expect(ModelsFolder.unavailableMessage(folder) == nil)
  }

  /// The real check, not a stand-in: a volume that is not mounted is not reachable.
  @Test func aVolumeThatIsNotMountedIsReportedForReal() {
    let folder = URL(fileURLWithPath: "/Volumes/no-such-disk-\(UUID().uuidString)/models")
    #expect(ModelsFolder.unavailableMessage(folder) != nil)
  }
}
