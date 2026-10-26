//  Created by Sukhrob on 25/08/26.
//

import AVFoundation
import SwiftUI
import UIKit

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private nonisolated(unsafe) var permissionGranted = false

    private nonisolated(unsafe) let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sessionQueue")

    private nonisolated(unsafe) var previewLayer = AVCaptureVideoPreviewLayer()

    /// Detector
    private nonisolated(unsafe) var videoOutput = AVCaptureVideoDataOutput()
    private nonisolated(unsafe) let gazeDetector = GazeDetector()
    private var boundaryEvaluator: GazeBoundaryEvaluator?
    private let calibrationCoordinator = CalibrationCoordinator()
    private var calibrationTargetView: CalibrationTargetView?
    private var isCalibrating = false

    private var hasAppeared = false
    private var isSessionRunning = false
    private var tutorialView: CalibrationTutorialView?
    private var feedbackView: EyeContactFeedbackView?

    private let liveConfidenceThreshold = 0.6

    override func viewDidLoad() {
        super.viewDidLoad()
        gazeDetector.onObservation = { [weak self] observation in
            self?.handleGazeObservation(observation)
        }
        installFeedbackUI()
        checkPermission()

        sessionQueue.async { [unowned self] in
            guard permissionGranted else { return }
            self.setUpCaptureSession()
            self.captureSession.startRunning()

            // Signal readiness back on main — same hop already used
            // below for adding the preview layer.
            DispatchQueue.main.async { [weak self] in
                self?.cameraSessionDidStart()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        showCalibrationTutorialIfReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    private func cameraSessionDidStart() {
        isSessionRunning = true
        showCalibrationTutorialIfReady()
    }

    private func showCalibrationTutorialIfReady() {
        guard hasAppeared, isSessionRunning, !isCalibrating, boundaryEvaluator == nil, tutorialView == nil else { return }

        let tutorial = CalibrationTutorialView(frame: view.bounds)
        tutorial.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tutorial.onStartTapped = { [weak self] in
            self?.startCalibration()
        }
        view.addSubview(tutorial)
        tutorialView = tutorial
    }

    nonisolated func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            requestPermission()
        default:
            permissionGranted = false
        }
    }

    nonisolated func requestPermission() {
        sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: .video) { [unowned self] granted in
            self.permissionGranted = granted
            self.sessionQueue.resume()
        }
    }

    nonisolated func setUpCaptureSession() {
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return }
        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }

        guard captureSession.canAddInput(videoDeviceInput) else { return }
        captureSession.addInput(videoDeviceInput)

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill

        previewLayer.connection?.videoRotationAngle = 0

        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sampleBufferQueue"))
        guard captureSession.canAddOutput(videoOutput) else { return }
        captureSession.addOutput(videoOutput)

        videoOutput.connection(with: .video)?.videoRotationAngle = 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewLayer.frame = self.view.bounds
            // Keep the camera behind UIKit overlays (tutorial, target dot,
            // and eye-contact border), even if the session starts late.
            self.view.layer.insertSublayer(self.previewLayer, at: 0)
        }
    }

    nonisolated func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        gazeDetector.handle(pixelBuffer)
    }

    private func handleGazeObservation(_ observation: GazeObservation) {
        switch observation {
        case let .detected(reading):
            if isCalibrating {
                feedbackView?.setState(.calibrating)
                calibrationCoordinator.handle(reading, timestamp: reading.timestamp)
                return
            }

            guard let evaluator = boundaryEvaluator else { return } // calibration not run yet
            guard reading.confidence >= liveConfidenceThreshold else {
                feedbackView?.setState(.lowConfidence)
                return
            }

            switch evaluator.evaluate(reading, viewBounds: view.bounds) {
            case .withinBounds:
                feedbackView?.setState(.eyeContact)
            case .exceeded:
                feedbackView?.setState(.lookingAway)
            }
        case .noFace:
            feedbackView?.setState(.noFace)
            if isCalibrating {
                // Same clock GazeDetector stamps readings with.
                calibrationCoordinator.faceLost(at: CACurrentMediaTime())
            }
        }
    }
}

private extension ViewController {
    func installFeedbackUI() {
        let feedback = EyeContactFeedbackView(frame: view.bounds)
        feedback.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        feedback.onRecalibrateTapped = { [weak self] in
            self?.presentCalibrationTutorial()
        }
        view.addSubview(feedback)
        feedbackView = feedback
    }

    func presentCalibrationTutorial() {
        guard !isCalibrating, tutorialView == nil else { return }
        let tutorial = CalibrationTutorialView(frame: view.bounds)
        tutorial.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tutorial.onStartTapped = { [weak self] in
            self?.startCalibration()
        }
        view.addSubview(tutorial)
        tutorialView = tutorial
    }

    func startCalibration() {
        guard !isCalibrating else { return }
        tutorialView?.removeFromSuperview()
        tutorialView = nil

        let inset: CGFloat = 60
        let bounds = view.bounds.insetBy(dx: inset, dy: inset)
        // Four corners plus the center, then a head-motion step on the
        // center dot; all of them feed the calibration fit.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let targets: [CalibrationCoordinator.Target] = [
            .fixation(at: CGPoint(x: bounds.minX, y: bounds.minY)),
            .fixation(at: CGPoint(x: bounds.maxX, y: bounds.minY)),
            .fixation(at: CGPoint(x: bounds.minX, y: bounds.maxY)),
            .fixation(at: CGPoint(x: bounds.maxX, y: bounds.maxY)),
            .fixation(at: center),
            .headMotion(at: center),
        ]

        let targetView = CalibrationTargetView(frame: view.bounds)
        targetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(targetView)
        calibrationTargetView = targetView

        feedbackView?.setState(.calibrating)

        calibrationCoordinator.onTargetChanged = { [weak self] target in
            self?.calibrationTargetView?.move(to: target.point, animated: true)
            self?.calibrationTargetView?.setInstruction(target.instruction)
        }
        calibrationCoordinator.onCollectingChanged = { [weak self] collecting in
            self?.calibrationTargetView?.setCollecting(collecting)
        }
        calibrationCoordinator.onFinished = { [weak self] result in
            guard let self else { return }
            self.calibrationTargetView?.removeFromSuperview()
            self.calibrationTargetView = nil
            self.isCalibrating = false

            switch result {
            case let .success(calibration):
                self.boundaryEvaluator = GazeBoundaryEvaluator(calibration: calibration)
                self.feedbackView?.setState(.eyeContact)
            case .timedOut:
                self.feedbackView?.setState(.calibrationFailed("Calibration timed out\nKeep your face in frame and try again."))
                self.presentCalibrationTutorial()
            case .insufficientData:
                self.feedbackView?.setState(.calibrationFailed("Calibration needs clearer readings\nTry again in brighter light."))
                self.presentCalibrationTutorial()
            }
        }

        isCalibrating = true
        calibrationCoordinator.begin(targets: targets)
    }
}

struct HostedViewController: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> some UIViewController {
        return ViewController()
    }

    func updateUIViewController(_: UIViewControllerType, context _: Context) {}
}
