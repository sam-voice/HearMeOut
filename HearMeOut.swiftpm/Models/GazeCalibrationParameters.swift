//  Created by Sukhrob on 07/09/26.
//

import Foundation

/// Degrees of gaze per unit of eye offset: converts Stage 3's unitless
/// -1...1 pupil offset into degrees so it can be added to head yaw/pitch.
/// 30° is a rough guess at comfortable eye rotation within the socket, not a
/// measured constant — tune it against your own logged data.
struct GazeCalibrationParameters {
    var eyeHorizontalScale: CGFloat = 30
    var eyeVerticalScale: CGFloat = 30
}
