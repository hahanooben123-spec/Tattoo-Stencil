import Foundation

/// Conservative working-set policy, not a promise about OS memory availability.
/// Fixed buffers are checked before allocation; data-dependent graphs have hard caps.
public struct ProcessingLimits: Sendable {
    public var memoryBudgetBytes: Int
    public var maximumGraphLinks: Int
    public var maximumRegions: Int
    public init(memoryBudgetBytes: Int = 768 * 1_048_576, maximumGraphLinks: Int = 400_000,
                maximumRegions: Int = 100_000) {
        self.memoryBudgetBytes = memoryBudgetBytes
        self.maximumGraphLinks = maximumGraphLinks; self.maximumRegions = maximumRegions
    }
    public static var device: ProcessingLimits {
        ProcessingLimits(memoryBudgetBytes: Int(min(UInt64(768 * 1_048_576), ProcessInfo.processInfo.physicalMemory / 5)))
    }
    public func estimatedBaseBytes(width: Int, height: Int) throws -> Int {
        let reserve = 32 * 1_048_576
        guard width > 1, height > 1, width <= (Int.max - reserve) / 48 / height else { throw StencilError.invalidImage }
        return width * height * 48 + reserve
    }
    public func bounded(width: Int, height: Int) throws -> ProcessingLimits {
        try Task.checkCancellation()
        guard memoryBudgetBytes > 0, maximumGraphLinks > 0, maximumRegions > 0 else { throw StencilError.invalidParameters }
        let base = try estimatedBaseBytes(width: width, height: height)
        guard base <= memoryBudgetBytes - min(memoryBudgetBytes, 4096) else {
            throw StencilError.memoryBudget(required: base, available: memoryBudgetBytes)
        }
        let remaining = memoryBudgetBytes - base
        return ProcessingLimits(memoryBudgetBytes: memoryBudgetBytes,
                                maximumGraphLinks: min(maximumGraphLinks, remaining / 2 / 320),
                                maximumRegions: min(maximumRegions, remaining / 2 / 512))
    }
}

/// Serializes synchronous decode/process/render operations, including cancelled jobs
/// while they unwind. Awaiting an actor never holds the UI thread.
public actor ProcessingLane {
    public init() {}
    public func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try operation()
    }
}
