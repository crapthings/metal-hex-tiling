import QuartzCore

final class FrameMonitor {
    private var lastPresentation: Double?
    private var intervalStart: Double?
    private var intervals: [Double] = []
    private var gpuTimes: [Double] = []
    private var cpuTimes: [Double] = []
    var onUpdate: ((String) -> Void)?

    // Called on the main run loop. FPS counts actual drawable presentations.
    func presented(at time: Double) {
        guard time > 0 else { return }
        defer { lastPresentation = time }
        guard let previous = lastPresentation, time > previous, time - previous < 0.5 else {
            intervalStart = time
            intervals.removeAll(); gpuTimes.removeAll(); cpuTimes.removeAll()
            return
        }
        intervals.append((time - previous) * 1000)
        guard let start = intervalStart, time - start >= 0.5 else { return }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        let gpu = gpuTimes.isEmpty ? "—" : String(format: "%.1f", gpuTimes.reduce(0, +) / Double(gpuTimes.count))
        let cpu = cpuTimes.isEmpty ? "—" : String(format: "%.1f", cpuTimes.reduce(0, +) / Double(cpuTimes.count))
        onUpdate?(String(format: "%.0f FPS | 帧 %.1f ms · 最慢 %.1f ms | CPU %@ ms · GPU %@ ms", 1000 / average, average, intervals.max() ?? 0, cpu, gpu))
        intervalStart = time
        intervals.removeAll(); gpuTimes.removeAll(); cpuTimes.removeAll()
    }

    func submitted(cpuMilliseconds: Double) { cpuTimes.append(cpuMilliseconds) }
    func completed(gpuMilliseconds: Double) {
        if gpuMilliseconds > 0 { gpuTimes.append(gpuMilliseconds) }
    }
}
