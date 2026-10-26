//  Created by Sam on 31/08/2026.
//

import CoreGraphics

/// Maps a gaze reading to an on-screen position. Each screen axis is a
/// weighted sum of these features plus an offset, fitted by least squares
/// over the calibration samples:
/// - gaze angles (horizontal, vertical): where the eyes and head point;
///   cross terms absorb small coupling between the axes.
/// - head yaw, pitch: lets the fit weigh head rotation differently from
///   eye rotation, which also absorbs any sign mismatch between Vision's
///   head angles and our eye angles.
/// - head position (x, y): moving the head sideways shifts where the same
///   gaze angle lands on the screen.
///
/// A fit from a single head pose doesn't hold once the head moves (Valenti
/// et al., TIP 2012; Lu et al., BMVC 2011), which is why calibration ends
/// with a head-motion step: the user keeps looking at one dot while moving
/// their head, so the head terms have data to be learned from.
struct GazeScreenCalibration {
    private let x: LinearModel
    private let y: LinearModel

    /// Shrinks feature weights slightly toward zero. Keeps the fit stable
    /// when features move together (e.g. the user barely moved their head
    /// during the head-motion step) — those weights then fade out instead
    /// of blowing up. Relative to standardized features, so it's unitless.
    private static let ridge: CGFloat = 0.01

    /// Returns nil with too few samples, samples from fewer than three
    /// distinct screen points, or gaze angles that never vary — any of
    /// which leaves the mapping undetermined.
    init?(samples: [CalibrationSample]) {
        let features = samples.map { Self.features(horizontalAngle: $0.horizontalAngle, verticalAngle: $0.verticalAngle, head: $0.head) }
        guard let featureCount = features.first?.count, samples.count >= 2 * featureCount else {
            return nil
        }

        let distinctPoints = Set(samples.map { "\($0.screenPoint.x),\($0.screenPoint.y)" })
        guard distinctPoints.count >= 3 else { return nil }

        // The ridge term keeps the fit solvable even if the gaze angles never
        // changed, but the result would be meaningless — reject it instead.
        let horizontal = samples.map(\.horizontalAngle)
        let vertical = samples.map(\.verticalAngle)
        guard horizontal.max()! > horizontal.min()!, vertical.max()! > vertical.min()! else {
            return nil
        }

        guard
            let x = LinearModel(features: features, targets: samples.map(\.screenPoint.x), ridge: Self.ridge),
            let y = LinearModel(features: features, targets: samples.map(\.screenPoint.y), ridge: Self.ridge)
        else {
            return nil
        }

        self.x = x
        self.y = y
    }

    func estimatedScreenPoint(for reading: GazeReading) -> CGPoint {
        let features = Self.features(horizontalAngle: reading.horizontalAngle, verticalAngle: reading.verticalAngle, head: reading.head)
        return CGPoint(x: x.predict(features), y: y.predict(features))
    }

    private static func features(horizontalAngle: CGFloat, verticalAngle: CGFloat, head: HeadPlacement) -> [CGFloat] {
        [horizontalAngle, verticalAngle, head.yaw, head.pitch, head.position.x, head.position.y]
    }
}

/// target ≈ intercept + Σ weight·(feature − mean) / scale, fitted by ridge
/// regression. Features are standardized first so one ridge strength suits
/// them all, whether degrees or image units.
private struct LinearModel {
    private let means: [CGFloat]
    private let scales: [CGFloat]
    private let weights: [CGFloat]
    private let intercept: CGFloat

    /// Below this standard deviation a feature counts as constant.
    private static let minScale: CGFloat = 1e-6

    init?(features: [[CGFloat]], targets: [CGFloat], ridge: CGFloat) {
        let n = CGFloat(features.count)
        let k = features[0].count

        let means = (0 ..< k).map { j in features.map { $0[j] }.reduce(0, +) / n }
        let scales = (0 ..< k).map { j -> CGFloat in
            let variance = features.map { pow($0[j] - means[j], 2) }.reduce(0, +) / n
            let std = sqrt(variance)
            // A constant feature standardizes to 0 everywhere, so its
            // weight only meets the ridge term and settles at 0.
            return std > Self.minScale ? std : 1
        }
        let standardized = features.map { row in (0 ..< k).map { (row[$0] - means[$0]) / scales[$0] } }

        let targetMean = targets.reduce(0, +) / n

        // Normal equations: (ZᵀZ + ridge·n·I) w = Zᵀ(t − t̄)
        var matrix = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: k), count: k)
        var vector = [CGFloat](repeating: 0, count: k)
        for (row, target) in zip(standardized, targets) {
            for i in 0 ..< k {
                vector[i] += row[i] * (target - targetMean)
                for j in 0 ..< k {
                    matrix[i][j] += row[i] * row[j]
                }
            }
        }
        for i in 0 ..< k {
            matrix[i][i] += ridge * n
        }

        guard let weights = Self.solve(matrix, vector) else { return nil }

        self.means = means
        self.scales = scales
        self.weights = weights
        intercept = targetMean
    }

    func predict(_ features: [CGFloat]) -> CGFloat {
        zip(features.indices, features).reduce(intercept) { sum, item in
            let (j, value) = item
            return sum + weights[j] * (value - means[j]) / scales[j]
        }
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [[CGFloat]], _ vector: [CGFloat]) -> [CGFloat]? {
        let size = vector.count
        var a = matrix
        var b = vector

        for column in 0 ..< size {
            var pivot = column

            for row in (column + 1) ..< size {
                if abs(a[row][column]) > abs(a[pivot][column]) {
                    pivot = row
                }
            }

            guard abs(a[pivot][column]) > 0.000001 else {
                return nil
            }

            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }

            for row in (column + 1) ..< size {
                let factor = a[row][column] / a[column][column]

                for col in column ..< size {
                    a[row][col] -= factor * a[column][col]
                }

                b[row] -= factor * b[column]
            }
        }

        var result = [CGFloat](repeating: 0, count: size)

        for row in stride(from: size - 1, through: 0, by: -1) {
            var value = b[row]

            for col in (row + 1) ..< size {
                value -= a[row][col] * result[col]
            }

            result[row] = value / a[row][row]
        }

        return result
    }
}
