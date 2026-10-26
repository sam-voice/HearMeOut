//  Created by Sam on 31/08/2026.
//

import CoreGraphics

final class CalibrationCoordinator {
    enum Result {
        case success(GazeScreenCalibration)
        case timedOut
        case insufficientData
    }

    enum State: Equatable {
        case idle
        case awaitingStability(pointIndex: Int)
        case collecting(pointIndex: Int)
        case finished
        case failed
    }

    struct Target {
        let point: CGPoint
        /// Once settled, keep collecting readings for this long; every
        /// reading becomes a calibration sample.
        let collectDuration: CFTimeInterval
        /// Shown to the user while this target is active.
        let instruction: String?
        /// A fixation target restarts after face loss, since the user may
        /// have looked away. The head-motion target keeps what it has:
        /// turning the head is expected to drop the face now and then.
        let restartsOnFaceLoss: Bool

        static func fixation(at point: CGPoint) -> Target {
            Target(point: point, collectDuration: 0.6, instruction: nil, restartsOnFaceLoss: true)
        }

        /// The user keeps looking at `point` while slowly moving their head,
        /// so calibration sees varied head poses for one known gaze target
        /// (Lu et al., BMVC 2011). Without this, the head-pose terms in
        /// `GazeScreenCalibration` have nothing to learn from.
        static func headMotion(at point: CGPoint) -> Target {
            Target(
                point: point,
                collectDuration: 4.0,
                instruction: "Keep looking at the dot\nand slowly tilt and turn your head",
                restartsOnFaceLoss: false
            )
        }
    }

    private(set) var state: State = .idle
    private var targets: [Target] = []
    private var currentIndex = 0
    private let session = CalibrationSession()

    /// Ignore readings for this long after a new target appears — filters
    /// out the transition while eyes are still moving toward the dot.
    private let settleDuration: CFTimeInterval = 0.4
    /// A target normally completes in settle + collect. If it hasn't within
    /// this much extra time — face out of frame, or detection flickering so
    /// the target keeps restarting — fail instead of stalling forever: the
    /// user has no other way out while calibration is running.
    private let timeoutSlack: CFTimeInterval = 3.0

    private var phaseStartTime: CFTimeInterval?
    private var pointStartTime: CFTimeInterval?
    private var collectedReadings: [GazeReading] = []

    var onTargetChanged: ((Target) -> Void)?
    var onCollectingChanged: ((Bool) -> Void)?
    var onFinished: ((Result) -> Void)?

    func begin(targets: [Target]) {
        session.reset()
        self.targets = targets
        currentIndex = 0
        moveToCurrentTarget()
    }

    private func moveToCurrentTarget() {
        guard currentIndex < targets.count else {
            state = .finished
            if let calibration = session.finish() {
                onFinished?(.success(calibration))
            } else {
                onFinished?(.insufficientData)
            }
            return
        }
        state = .awaitingStability(pointIndex: currentIndex)
        phaseStartTime = nil
        pointStartTime = nil
        collectedReadings = []
        onTargetChanged?(targets[currentIndex])
        onCollectingChanged?(false)
    }

    /// Feed every GazeReading here while calibration is running. Call
    /// `faceLost(at:)` instead when an observation comes back as `.noFace`.
    func handle(_ reading: GazeReading, timestamp: CFTimeInterval) {
        guard !hasTimedOut(at: timestamp) else { return }

        switch state {
        case let .awaitingStability(index):
            if phaseStartTime == nil { phaseStartTime = timestamp }
            guard let start = phaseStartTime, timestamp - start >= settleDuration else { return }
            state = .collecting(pointIndex: index)
            phaseStartTime = timestamp
            onCollectingChanged?(true)

        case let .collecting(index):
            collectedReadings.append(reading)
            guard let start = phaseStartTime, timestamp - start >= targets[index].collectDuration else { return }
            recordSamples(pointIndex: index)
            currentIndex += 1
            moveToCurrentTarget()

        case .idle, .finished, .failed:
            break
        }
    }

    /// Call when the Detector reports `.noFace` while calibrating — for a
    /// fixation target, a gap here means whatever's been collected so far
    /// is unreliable, so restart its settle phase rather than quietly
    /// keeping readings from either side of a dropout.
    func faceLost(at timestamp: CFTimeInterval) {
        guard !hasTimedOut(at: timestamp) else { return }

        switch state {
        case let .awaitingStability(index), let .collecting(index):
            guard targets[index].restartsOnFaceLoss else { return }
            resetCurrentPoint(index: index)
        case .idle, .finished, .failed:
            return
        }
    }

    /// Leaves `pointStartTime` alone on purpose: the timeout measures how
    /// long the target has been showing, so face loss mustn't restart it.
    private func resetCurrentPoint(index: Int) {
        state = .awaitingStability(pointIndex: index)
        phaseStartTime = nil
        collectedReadings = []
        onCollectingChanged?(false)
    }

    /// Starts the current target's clock on its first event and fails the
    /// calibration once that target has been showing too long. Checked on
    /// face loss as well as on readings — with the face fully out of frame,
    /// `.noFace` is the only event that arrives.
    private func hasTimedOut(at timestamp: CFTimeInterval) -> Bool {
        let index: Int
        switch state {
        case let .awaitingStability(i), let .collecting(i):
            index = i
        case .idle, .finished, .failed:
            return false
        }

        guard let pointStart = pointStartTime else {
            pointStartTime = timestamp
            return false
        }
        let timeout = settleDuration + targets[index].collectDuration + timeoutSlack
        guard timestamp - pointStart > timeout else { return false }

        state = .failed
        onFinished?(.timedOut)
        return true
    }

    /// Every reading becomes its own sample rather than being reduced to one
    /// median per target: the fit now has six features to learn, and the
    /// head-motion target only helps if its varied head poses survive.
    private func recordSamples(pointIndex: Int) {
        for reading in collectedReadings {
            session.recordSample(at: targets[pointIndex].point, reading: reading)
        }
    }
}
