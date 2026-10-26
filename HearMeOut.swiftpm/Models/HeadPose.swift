//  Created by Sukhrob on 28/08/26.
//

import Foundation

struct HeadPose {
    let roll: CGFloat?
    let yaw: CGFloat?
    let pitch: CGFloat?
}

/// Where the head is and which way it faces. Carried alongside the gaze
/// angles so calibration can learn how head movement shifts where a given
/// gaze angle lands on the screen.
struct HeadPlacement {
    /// Head yaw/pitch in degrees, in Vision's sign convention. Calibration
    /// learns their weight and sign, so the convention doesn't have to
    /// match the eye angles'.
    let yaw: CGFloat
    let pitch: CGFloat

    /// Face-box center in GazeDetector's aspect-corrected image coordinates.
    /// Moving the head sideways — which rolling it about the neck also does —
    /// shifts the eyes relative to the screen, so the same gaze angle lands
    /// on a different point.
    let position: CGPoint
}

struct GazeEstimate {
    /// Approximate total angular deviation from looking straight at the
    /// camera, in degrees, along the image's horizontal/vertical axes.
    /// Positive/negative direction follows whatever Vision's own yaw/pitch
    /// sign convention is — verify this empirically
    let horizontalAngle: CGFloat
    let verticalAngle: CGFloat
    let confidence: Double
    let head: HeadPlacement
}
