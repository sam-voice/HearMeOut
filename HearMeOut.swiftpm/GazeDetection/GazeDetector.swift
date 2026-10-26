//  Created by Sukhrob on 25/08/26.
//

import AVFoundation
import CoreVideo
import Vision

final class GazeDetector {
    private let minFrameInterval: CFTimeInterval = 1.0 / 15.0 // 15 fps
    private var lastProcessedTime: CFTimeInterval = 0

    /// Called once per processed frame with the latest observation.
    /// Marked `@MainActor @Sendable` rather than a plain closure type:
    /// `@MainActor` tells the compiler this closure only ever runs on
    /// the main actor — which is what makes it safe for the consumer to
    /// capture `self` from a UIViewController when assigning this.
    /// `@Sendable` is what allows the closure *value* to be captured
    /// here and carried across the hop below.
    var onObservation: (@MainActor @Sendable (GazeObservation) -> Void)?

    /// Reused across every frame on purpose
    private let sequenceHandler = VNSequenceRequestHandler()
    private let gazeSmoother = GazeSmoother()
    private let gazeZoneClassifier = GazeZoneClassifier()

    /// Verified against .portrait capture orientation on a front camera.
    /// Re-check this if you ever change videoOrientation on the capture
    /// connection, or support device rotation.
    private let orientation: CGImagePropertyOrientation = .right

    /// Below this, a single eye's reading is treated as unusable (e.g. a
    /// blink) rather than included at near-zero weight. Tune against logged
    /// EAR values from Stage 3 rather than trusting this number blindly.
    private let minUsableConfidence: Double = 0.15
    private let calibration = GazeCalibrationParameters()

    /// Head yaw/pitch beyond this (radians, ~35°) is clamped before undoing
    /// foreshortening in Stage 3. Past this angle the flat-eye approximation
    /// breaks down and Vision's pose estimate gets noisy, so the correction
    /// would amplify error rather than remove it.
    private let maxForeshorteningAngle: CGFloat = 35 * .pi / 180

    /// IMPORTANT: this method assumes it is always invoked back-to-back
    /// from the same serial queue AVFoundation delivers frames on. That's
    /// why `lastProcessedTime` is read and written here with no lock —
    /// AVFoundation's own guarantee that delegate calls never overlap on a
    /// given queue is what makes that safe. If this were ever called from
    /// more than one queue, that guarantee breaks and this needs a lock.
    func handle(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastProcessedTime >= minFrameInterval else { return }
        lastProcessedTime = now

        process(pixelBuffer, timestamp: now)
    }
}

private extension GazeDetector {
    func process(_ pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) {
        let dimensions = effectiveImageDimensions(pixelBuffer: pixelBuffer)

        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            self?.handleLandmarksResult(request: request, error: error, timestamp: timestamp, imageDimensions: dimensions)
        }

        do {
            // Synchronous: `handleLandmarksResult` runs before this call
            // returns, on whatever queue `process` was called from.
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            // Transient Vision failures happen occasionally (e.g. the pixel
            // buffer became invalid mid-flight). Drop the frame rather than
            // treating this as a hard failure — the next frame will retry.
        }
    }

    func handleLandmarksResult(request: VNRequest, error: Error?, timestamp: CFTimeInterval, imageDimensions: (width: CGFloat, height: CGFloat)) {
        guard error == nil, let observations = request.results as? [VNFaceObservation] else {
            reportNoFace()
            return
        }
        guard let primaryFace = observations.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) else {
            reportNoFace()
            return
        }
        guard let landmarks = primaryFace.landmarks else {
            reportNoFace()
            return
        }
        handleFace(primaryFace, landMarks: landmarks, timestamp: timestamp, imageDimensions: imageDimensions)
    }

    func reportNoFace() {
        gazeSmoother.reset()
        emit(.noFace)
    }

    func handleFace(_ face: VNFaceObservation, landMarks: VNFaceLandmarks2D, timestamp: CFTimeInterval, imageDimensions: (width: CGFloat, height: CGFloat)) {
        let faceBox = face.boundingBox
        let aspectCorrection = imageDimensions.height / imageDimensions.width
        let pose = headPose(from: face)

        let leftEye = eyeGeometry(contour: landMarks.leftEye, pupil: landMarks.leftPupil, faceBox: faceBox, aspectCorrection: aspectCorrection)
        let rightEye = eyeGeometry(contour: landMarks.rightEye, pupil: landMarks.rightPupil, faceBox: faceBox, aspectCorrection: aspectCorrection)

        guard let faceAxis = faceAxis(left: leftEye, right: rightEye) else {
            reportNoFace()
            return
        }

        let leftReading = leftEye.map { eyeReading($0, faceAxis: faceAxis, pose: pose) }
        let rightReading = rightEye.map { eyeReading($0, faceAxis: faceAxis, pose: pose) }

        guard let combinedEyeReading = combine(left: leftReading, right: rightReading) else {
            reportNoFace()
            return
        }

        let facePosition = CGPoint(x: faceBox.midX, y: faceBox.midY * aspectCorrection)
        let estimate = gazeEstimate(eyeReading: combinedEyeReading, pose: pose, faceAxis: faceAxis, facePosition: facePosition)
        let smoothedEstimate = gazeSmoother.update(with: estimate, at: timestamp)

        let classification = gazeZoneClassifier.classify(
            horizontalAngle: smoothedEstimate.horizontalAngle,
            verticalAngle: smoothedEstimate.verticalAngle,
            timestamp: timestamp
        )

        let reading = GazeReading(
            gaze: classification.zone,
            horizontalAngle: smoothedEstimate.horizontalAngle,
            verticalAngle: smoothedEstimate.verticalAngle,
            confidence: smoothedEstimate.confidence,
            head: smoothedEstimate.head,
            timeSinceCentered: classification.timeSinceCentered,
            timestamp: timestamp
        )

        emit(.detected(reading))
    }
}

// MARK: - Stage 3

private extension GazeDetector {
    /// One eye's landmarks in image space, before anything is measured
    /// relative to the face's orientation.
    struct EyeGeometry {
        let contour: [CGPoint]
        let pupilCenter: CGPoint
        /// Midpoint between the two eye corners.
        let center: CGPoint
        /// Unit vector from corner to corner, pointing toward larger image-x.
        let cornerAxis: CGPoint
        let halfWidth: CGFloat
    }

    func imagePoint(from region: VNFaceLandmarkRegion2D, faceBox: CGRect, aspectCorrection: CGFloat) -> [CGPoint] {
        region.normalizedPoints.map { point in
            let x = faceBox.origin.x + point.x * faceBox.width
            let y = faceBox.origin.y + point.y * faceBox.height

            return CGPoint(x: x, y: y * aspectCorrection)
        }
    }

    func corners(of eyePoints: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard eyePoints.count >= 2 else { return nil }

        var best: (CGPoint, CGPoint, CGFloat) = (eyePoints[0], eyePoints[0], 0)

        for i in 0 ..< eyePoints.count {
            for j in (i + 1) ..< eyePoints.count {
                let dx = eyePoints[i].x - eyePoints[j].x
                let dy = eyePoints[i].y - eyePoints[j].y
                let distSq = dx * dx + dy * dy
                if distSq > best.2 {
                    best = (eyePoints[i], eyePoints[j], distSq)
                }
            }
        }

        return (best.0, best.1)
    }

    func normalize(_ v: CGPoint) -> CGPoint {
        let length = sqrt(v.x * v.x + v.y * v.y)
        guard length > 0 else { return .zero }

        return CGPoint(x: v.x / length, y: v.y / length)
    }

    /// The dot product of (pupil - eyeCenter) with the unit axis vector gives you a signed distance:
    /// how far the pupil sits along that axis direction
    func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        a.x * b.x + a.y * b.y
    }

    func eyeGeometry(
        contour: VNFaceLandmarkRegion2D?,
        pupil: VNFaceLandmarkRegion2D?,
        faceBox: CGRect,
        aspectCorrection: CGFloat
    ) -> EyeGeometry? {
        guard let contour, let pupil else { return nil }

        let eyePoints = imagePoint(from: contour, faceBox: faceBox, aspectCorrection: aspectCorrection)
        let pupilPoints = imagePoint(from: pupil, faceBox: faceBox, aspectCorrection: aspectCorrection)

        guard !pupilPoints.isEmpty else { return nil }

        guard let (cornerA, cornerB) = corners(of: eyePoints) else { return nil }

        let halfWidth = sqrt(pow(cornerB.x - cornerA.x, 2) + pow(cornerB.y - cornerA.y, 2)) / 2
        guard halfWidth > 0 else { return nil }

        return EyeGeometry(
            contour: eyePoints,
            pupilCenter: CGPoint(
                x: pupilPoints.map(\.x).reduce(0, +) / CGFloat(pupilPoints.count),
                y: pupilPoints.map(\.y).reduce(0, +) / CGFloat(pupilPoints.count)
            ),
            center: CGPoint(
                x: (cornerA.x + cornerB.x) / 2,
                y: (cornerA.y + cornerB.y) / 2
            ),
            cornerAxis: normalize(canonicalAxis(cornerA: cornerA, cornerB: cornerB)),
            halfWidth: halfWidth
        )
    }

    /// The face's horizontal axis in the image: the line through both eye
    /// centers, as in Zhang et al.'s data normalization (ETRA 2018). Its
    /// angle is the head's roll as the camera sees it, measured in our own
    /// image coordinates — so unlike Vision's roll there's no sign convention
    /// to get wrong. Both eyes are measured along this one shared axis, which
    /// is steadier than each eye's own short corner line. Falls back to that
    /// corner line when only one eye was found.
    func faceAxis(left: EyeGeometry?, right: EyeGeometry?) -> CGPoint? {
        switch (left, right) {
        case let (l?, r?):
            let axis = normalize(canonicalAxis(cornerA: l.center, cornerB: r.center))
            return axis == .zero ? l.cornerAxis : axis
        case let (l?, nil):
            return l.cornerAxis
        case let (nil, r?):
            return r.cornerAxis
        case (nil, nil):
            return nil
        }
    }

    /// Measures the pupil's offset in the face's own frame — `faceAxis` and
    /// its perpendicular — so tilting the head doesn't change the reading.
    func eyeReading(_ eye: EyeGeometry, faceAxis: CGPoint, pose: HeadPose) -> EyeReading {
        let perpendicular = CGPoint(x: -faceAxis.y, y: faceAxis.x) // rotate 90°

        let offset = CGPoint(
            x: eye.pupilCenter.x - eye.center.x,
            y: eye.pupilCenter.y - eye.center.y
        )

        // Yaw shrinks both this offset and the eye width we divide by, so it
        // cancels out here.
        let horizontal = dot(offset, faceAxis) / eye.halfWidth

        // Eye height is a fraction of its width in practice; this scale factor
        // is an approximation, revisit if vertical readings feel too sensitive.
        // Pitch shrinks vertical pupil movement by cos(pitch) but leaves the
        // width alone, so divide that back out.
        let pitch = min(abs(pose.pitch ?? 0), maxForeshorteningAngle)
        let vertical = dot(offset, perpendicular) / (eye.halfWidth * 0.5) / cos(pitch)

        let confidence = eyeOpenness(
            eye.contour,
            eyeCenter: eye.center,
            perpendicular: perpendicular,
            width: eye.halfWidth * 2,
            pose: pose
        )

        return EyeReading(horizontalOffset: horizontal, verticalOffset: vertical, confidence: confidence)
    }

    /// Eye Aspect Ratio, adapted from Soukupová & Čech's blink-detection
    /// approach: ratio of eye height to eye width. Drops sharply during a
    /// blink, which we use as a simple confidence signal.
    ///
    /// Head-pose compensation:
    /// - Roll (tilting the head sideways): height is measured along the
    ///   face's perpendicular axis, not image-y, so it doesn't change as
    ///   the eye rotates in the image. Measuring image-y instead made a
    ///   tilted open eye read as wide open, hiding blinks.
    /// - Yaw/pitch (turning/nodding): these foreshorten the eye's width by
    ///   cos(yaw) and height by cos(pitch), so the observed ratio is scaled
    ///   by cos(pitch) / cos(yaw). Multiplying by the inverse undoes that,
    ///   e.g. looking down at the phone no longer reads as a half-closed eye.
    func eyeOpenness(
        _ eyePoints: [CGPoint],
        eyeCenter: CGPoint,
        perpendicular: CGPoint,
        width: CGFloat,
        pose: HeadPose
    ) -> Double {
        guard eyePoints.count >= 4, width > 0 else { return 0 }

        let projections = eyePoints.map { point in
            dot(CGPoint(x: point.x - eyeCenter.x, y: point.y - eyeCenter.y), perpendicular)
        }
        let height = (projections.max() ?? 0) - (projections.min() ?? 0)

        let yaw = min(abs(pose.yaw ?? 0), maxForeshorteningAngle)
        let pitch = min(abs(pose.pitch ?? 0), maxForeshorteningAngle)
        let foreshortening = cos(yaw) / cos(pitch)

        let ear = Double(height / width * foreshortening)
        // Typical open-eye EAR is roughly 0.2–0.35; tune against your own
        // logged values rather than trusting this number blindly.

        return min(1.0, max(0.0, ear / 0.3))
    }

    /// Ensures an axis vector always points toward larger image-x,
    /// regardless of which end point happened to come first (e.g. which
    /// corner the distance search returned). Without this, left and right
    /// eye readings can end up with inconsistent sign conventions purely by
    /// iteration-order accident.
    func canonicalAxis(cornerA: CGPoint, cornerB: CGPoint) -> CGPoint {
        let raw = CGPoint(x: cornerB.x - cornerA.x, y: cornerB.y - cornerA.y)
        return raw.x >= 0 ? raw : CGPoint(x: -raw.x, y: -raw.y)
    }
}

// MARK: Stage 4

private extension GazeDetector {
    func combine(left: EyeReading?, right: EyeReading?) -> CombinedGazeReading? {
        let usableLeft = left.flatMap { $0.confidence >= minUsableConfidence ? $0 : nil }
        let usableRight = right.flatMap { $0.confidence >= minUsableConfidence ? $0 : nil }

        switch (usableLeft, usableRight) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            // Only one eye usable — use it, but note the reduced confidence rather than treating
            // a monocular reading as equally reliable as a binocular one.
            return CombinedGazeReading(
                horizontalOffset: l.horizontalOffset,
                verticalOffset: l.verticalOffset,
                confidence: l.confidence * 0.75
            )
        case (nil, let r?):
            return CombinedGazeReading(
                horizontalOffset: r.horizontalOffset,
                verticalOffset: r.verticalOffset,
                confidence: r.confidence * 0.75
            )
        case let (l?, r?):
            let totalWeight = l.confidence + r.confidence
            // Both passed the minUsableConfidence check above, so totalWeight > 0 here — safe to divide.
            let horizontal = (l.horizontalOffset * l.confidence + r.horizontalOffset * r.confidence) / totalWeight
            let vertical = (l.verticalOffset * l.confidence + r.verticalOffset * r.confidence) / totalWeight

            return CombinedGazeReading(
                horizontalOffset: horizontal,
                verticalOffset: vertical,
                confidence: (l.confidence + r.confidence) / 2
            )
        }
    }
}

// MARK: Stage 5

private extension GazeDetector {
    func headPose(from face: VNFaceObservation) -> HeadPose {
        let roll = face.roll.map { CGFloat(truncating: $0) }
        let yaw = face.yaw.map { CGFloat(truncating: $0) }
        let pitch = face.pitch.map { CGFloat(truncating: $0) }

        return HeadPose(roll: roll, yaw: yaw, pitch: pitch)
    }

    func gazeEstimate(eyeReading: CombinedGazeReading, pose: HeadPose, faceAxis: CGPoint, facePosition: CGPoint) -> GazeEstimate {
        let yawDegrees = (pose.yaw ?? 0) * 180 / .pi
        let pitchDegrees = (pose.pitch ?? 0) * 180 / .pi

        // Eye-in-head angles, along the face's own axes.
        let eyeYaw = eyeReading.horizontalOffset * calibration.eyeHorizontalScale
        let eyePitch = eyeReading.verticalOffset * calibration.eyeVerticalScale

        // Rotate them into image axes before adding head yaw/pitch, which
        // describe the head relative to the camera. With the head tilted by
        // θ, the face's axes are rotated by θ against the screen: looking
        // straight down at the screen reads as partly sideways along the eye
        // line, and adding that unrotated mixed the two frames. Upright
        // (θ = 0) this changes nothing. faceAxis is (cos θ, sin θ).
        let eyeHorizontal = eyeYaw * faceAxis.x - eyePitch * faceAxis.y
        let eyeVertical = eyeYaw * faceAxis.y + eyePitch * faceAxis.x

        // Vision's yaw/pitch are taken as already camera-relative and added
        // as-is. If their sign or scale doesn't match the eye angles, the
        // calibration's separate head-pose terms absorb it.
        let horizontalAngle = yawDegrees + eyeHorizontal
        let verticalAngle = pitchDegrees + eyeVertical

        var confidence = eyeReading.confidence
        if pose.yaw == nil { confidence *= 0.85 }
        if pose.pitch == nil { confidence *= 0.85 }

        return GazeEstimate(
            horizontalAngle: horizontalAngle,
            verticalAngle: verticalAngle,
            confidence: confidence,
            head: HeadPlacement(yaw: yawDegrees, pitch: pitchDegrees, position: facePosition)
        )
    }
}

// MARK: Stage 8

private extension GazeDetector {
    func emit(_ observation: GazeObservation) {
        // Task { @MainActor in } gives the compiler an actual, provable guarantee that
        // this hop lands on the main actor before `callback` runs — unlike DispatchQueue.main.async,
        // which is only a runtime convention as far as the type system is concerned.
        let callback = onObservation
        Task { @MainActor in
            callback?(observation)
        }
    }
}

private extension GazeDetector {
    /// Vision's normalized coordinates are relative to the image *after*
    /// applying `orientation` — a 90° rotation (.left/.right) swaps which
    /// of the buffer's raw dimensions is "width" vs "height" from Vision's
    /// point of view. Get this wrong and the aspect correction below makes
    /// things worse, not better.
    func effectiveImageDimensions(pixelBuffer: CVPixelBuffer) -> (width: CGFloat, height: CGFloat) {
        let rawWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let rawHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return (rawHeight, rawWidth)
        default:
            return (rawWidth, rawHeight)
        }
    }
}
