//  Created by Sam on 31/08/2026.
//

import UIKit

final class CalibrationTargetView: UIView {
    private let dot = UIView()
    private let instructionBackground = UIView()
    private let instructionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dot.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 12
        addSubview(dot)

        instructionBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        instructionBackground.layer.cornerRadius = 12
        instructionBackground.isHidden = true
        instructionBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(instructionBackground)

        instructionLabel.font = .preferredFont(forTextStyle: .headline)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 0
        instructionLabel.textColor = .white
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionBackground.addSubview(instructionLabel)

        // Below the center, where the head-motion dot sits, so the text
        // stays close to where the user is already looking.
        NSLayoutConstraint.activate([
            instructionBackground.topAnchor.constraint(equalTo: centerYAnchor, constant: 48),
            instructionBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructionBackground.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            instructionBackground.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            instructionLabel.topAnchor.constraint(equalTo: instructionBackground.topAnchor, constant: 10),
            instructionLabel.bottomAnchor.constraint(equalTo: instructionBackground.bottomAnchor, constant: -10),
            instructionLabel.leadingAnchor.constraint(equalTo: instructionBackground.leadingAnchor, constant: 16),
            instructionLabel.trailingAnchor.constraint(equalTo: instructionBackground.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func move(to point: CGPoint, animated: Bool) {
        let apply = { self.dot.center = point }
        animated ? UIView.animate(withDuration: 0.3, animations: apply) : apply()
    }

    /// Visual cue that a sample is actively being recorded — gives the
    /// user a reason to hold still right at the moment it matters.
    func setCollecting(_ collecting: Bool) {
        if collecting {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.4
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer.add(pulse, forKey: "pulse")
        } else {
            dot.layer.removeAnimation(forKey: "pulse")
        }
    }

    /// Pass nil to hide the instruction.
    func setInstruction(_ text: String?) {
        instructionLabel.text = text
        instructionBackground.isHidden = text == nil
    }
}
