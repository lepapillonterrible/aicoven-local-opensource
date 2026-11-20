import Foundation

/// The pictures a turn's tools made for its model to look at (frames of
/// a Figma file, rendered). They go to the model with the turn's later
/// requests and nowhere else: they are not stored, not shown in the
/// thread, and not part of any tool's result or of a log.
///
/// A turn has one only where its model can be sent pictures; without it
/// a tool that makes them is refused. Sendable by hand, under `lock`.
final nonisolated class TurnPictures: @unchecked Sendable {
    /// The most times a turn renders frames (as the cloud app has it for
    /// a run): each can add three pictures to every later request.
    static let mostRenders = 2

    private let lock = NSLock()
    private var kept: [LLMImage] = []
    private var renders = 0

    /// The pictures so far, in the order they were made.
    var images: [LLMImage] {
        lock.withLock { kept }
    }

    /// Adds pictures; which of the turn's tool pictures they are, counted
    /// from 1 (nil if none were given).
    @discardableResult
    func add(_ images: [LLMImage]) -> ClosedRange<Int>? {
        guard !images.isEmpty else { return nil }
        return lock.withLock {
            let first = kept.count + 1
            kept += images
            return first ... kept.count
        }
    }

    /// Takes one of the turn's renders; false when they are used up.
    func takeRender() -> Bool {
        lock.withLock {
            guard renders < Self.mostRenders else { return false }
            renders += 1
            return true
        }
    }

    /// Gives back a render that came to nothing (the call was refused or
    /// failed before Figma rendered anything).
    func giveBackRender() {
        lock.withLock { renders = max(0, renders - 1) }
    }
}
