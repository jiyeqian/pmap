import Testing
@testable import PmapCore

@Suite("端口灯轮播")
struct CarouselTests {
    @Test("按端口顺序使用各颜色时长并循环")
    func weightedCycle() {
        var carousel = PortCarousel()
        let initial = carousel.update([.red, .green, .gray])
        #expect(initial)
        var durations: [Double] = []
        for _ in 0..<6 {
            durations.append(carousel.current!.displayDuration)
            carousel.advance()
        }
        #expect(durations == [2, 1.5, 0.5, 2, 1.5, 0.5])
    }

    @Test("无关刷新保留当前时隙，颜色变化立即重置")
    func refresh() {
        var carousel = PortCarousel()
        _ = carousel.update([.red, .green])
        carousel.advance()
        let unchanged = carousel.update([.red, .green])
        #expect(!unchanged)
        #expect(carousel.current == .green)
        let changed = carousel.update([.gray, .green])
        #expect(changed)
        #expect(carousel.current == .gray)
        #expect(carousel.current?.displayDuration == 0.5)
        let emptied = carousel.update([])
        #expect(emptied)
        carousel.advance()
        #expect(carousel.current == nil)
    }

    @Test("单端口沿用同一轮播流程，同色端口保留各自时隙")
    func singleAndRepeated() {
        var carousel = PortCarousel()
        _ = carousel.update([.red])
        for _ in 0..<3 {
            carousel.advance()
            #expect(carousel.current == .red)
        }
        _ = carousel.update([.gray, .gray, .green])
        carousel.advance()
        #expect(carousel.current == .gray)
        carousel.advance()
        #expect(carousel.current == .green)
    }
}
