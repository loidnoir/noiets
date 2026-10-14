import AppKit
import Testing
import RenderKit

@Suite struct DirectionalFocusTests {
    private let search = CGRect(x: 20, y: 400, width: 600, height: 30)

    @Test func usesDirectionsRatherThanRegistrationOrder() {
        let left = CGRect(x: -100, y: 400, width: 50, height: 30)
        let right = CGRect(x: 640, y: 400, width: 50, height: 30)
        let down = CGRect(x: 20, y: 200, width: 600, height: 180)
        let up = CGRect(x: 20, y: 500, width: 600, height: 30)
        let candidates = [up, down, right, left]
        #expect(DirectionalFocus.nearest(from: search, candidates: candidates, direction: .left) == 3)
        #expect(DirectionalFocus.nearest(from: search, candidates: candidates, direction: .right) == 2)
        #expect(DirectionalFocus.nearest(from: search, candidates: candidates, direction: .down) == 1)
        #expect(DirectionalFocus.nearest(from: search, candidates: candidates, direction: .up) == 0)
    }

    @Test func favoursAlignmentAndSkipsZeroSizedRegions() {
        let farAligned = CGRect(x: 640, y: 400, width: 50, height: 30)
        let closeDiagonal = CGRect(x: 610, y: 300, width: 50, height: 30)
        #expect(DirectionalFocus.nearest(from: search, candidates: [closeDiagonal, farAligned], direction: .right) == 1)
        #expect(DirectionalFocus.nearest(from: search, candidates: [.zero], direction: .down) == nil)
        #expect(DirectionalFocus.nearest(from: search, candidates: [], direction: .left) == nil)
    }

    @Test func wideFieldBeatsSmallDiagonalSelectorFromSave() {
        let save = CGRect(x: 950, y: 400, width: 40, height: 24)
        let field = CGRect(x: 20, y: 400, width: 922, height: 24)
        let tags = CGRect(x: 840, y: 200, width: 152, height: 180)
        #expect(DirectionalFocus.nearest(from: save, candidates: [tags, field], direction: .left) == 1)
    }

    @Test func resizingChangesNavigationAndEdgesDoNotWrap() {
        let graph = CGRect(x: 20, y: 200, width: 600, height: 180)
        let sideTags = CGRect(x: 640, y: 200, width: 150, height: 180)
        let topTags = CGRect(x: 20, y: 390, width: 200, height: 26)
        #expect(DirectionalFocus.nearest(from: graph, candidates: [sideTags], direction: .right) == 0)
        #expect(DirectionalFocus.nearest(from: graph, candidates: [topTags], direction: .up) == 0)
        #expect(DirectionalFocus.nearest(from: graph, candidates: [topTags], direction: .right) == nil)
        #expect(DirectionalFocus.nearest(from: graph, candidates: [sideTags], direction: .left) == nil)
    }

    @Test func paletteHas48DistinctCandidatesAndWraps() throws {
        #expect(TagPalette.count == 48)
        let colors = (0..<TagPalette.count).map { TagPalette.color(at: $0) }
        #expect(Set(colors.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" }).count == 48)
        #expect(TagPalette.color(at: 48) == TagPalette.color(at: 0))
        #expect(TagPalette.color(at: -1) == TagPalette.color(at: 47))
        let first = try #require(colors[0].usingColorSpace(.sRGB))
        #expect(abs(first.redComponent - 222.0 / 255.0) < 0.0001)
    }
}
