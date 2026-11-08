import Testing
@testable import HerbsTerminal

@Suite("Parity scene")
struct ParitySceneTests {
    @Test func onlyTheParityCopyHonoursTheFlag() {
        let arguments = ["HerbsTerminal", "--parity-scene", "main"]
        #expect(ParityScene.scene(in: arguments, bundleIdentifier: ParityScene.bundleIdentifier) == "main")
        #expect(ParityScene.scene(in: arguments, bundleIdentifier: "org.herbsterminal.app") == nil)
        #expect(ParityScene.scene(in: arguments, bundleIdentifier: nil) == nil)
    }

    @Test func aFlagWithoutANameIsIgnored() {
        #expect(ParityScene.scene(in: ["HerbsTerminal", "--parity-scene"], bundleIdentifier: ParityScene.bundleIdentifier) == nil)
    }

    @Test func theTestRunIsNotAParityScene() {
        #expect(!ParityScene.isActive)
    }

    @Test func theShellIsPlainAndPrivate() {
        let environment = ParityScene.shellEnvironment()
        #expect(environment["HOME"] == ParityScene.home.path)
        #expect(environment["PS1"] == "$ ")
        #expect(environment["ZDOTDIR"] == nil)
    }
}
