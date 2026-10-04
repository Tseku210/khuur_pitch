import AVFoundation
import Flutter
import UIKit

public class KhuurPitchPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private enum Capture {
    case idle
    case running(FlutterEventSink, AVAudioEngine)
    case interrupted(FlutterEventSink)
  }

  private enum MicPermission: String {
    case granted, denied, permanentlyDenied
  }

  private var capture = Capture.idle
  private var observers: [NSObjectProtocol] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = KhuurPitchPlugin()
    let control = FlutterMethodChannel(
      name: "khuur_pitch/control", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: control)
    FlutterEventChannel(name: "khuur_pitch/audio", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  override init() {
    super.init()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak self] in self?.interruption($0) },
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
      ) { [weak self] in self?.configurationChange($0) },
    ]
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    stop()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkPermission":
      result(Self.permission(AVCaptureDevice.authorizationStatus(for: .audio)).rawValue)
    case "requestPermission":
      let status = AVCaptureDevice.authorizationStatus(for: .audio)
      guard status == .notDetermined else {
        result(Self.permission(status).rawValue)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        let answer: MicPermission = granted ? .granted : .permanentlyDenied
        DispatchQueue.main.async { result(answer.rawValue) }
      }
    case "openAppSettings":
      UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func permission(_ status: AVAuthorizationStatus) -> MicPermission {
    switch status {
    case .authorized: return .granted
    case .notDetermined: return .denied
    case .denied, .restricted: return .permanentlyDenied
    @unknown default: return .permanentlyDenied
    }
  }

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    stop()
    start(events)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    return nil
  }

  private func start(_ sink: @escaping FlutterEventSink) {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      fail(sink, "permissionDenied", "Microphone access is not granted")
      return
    }
    // The input node reports a 0 Hz format until the session records and is active.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true)
    } catch {
      fail(sink, "audioFailed", "Audio session: \(error.localizedDescription)")
      return
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    // A tap in any format other than the hardware one can raise an uncatchable NSException.
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      fail(sink, "noInput", "No audio input: \(format)")
      return
    }

    let engineID = ObjectIdentifier(engine)
    let rate = Int(format.sampleRate)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let channel = buffer.floatChannelData?[0] else { return }
      let data = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
      DispatchQueue.main.async {
        guard let self, case .running(let sink, let engine) = self.capture,
          ObjectIdentifier(engine) == engineID
        else { return }
        sink(["sampleRate": rate, "samples": FlutterStandardTypedData(float32: data)])
      }
    }

    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      fail(sink, "audioFailed", "Audio engine: \(error.localizedDescription)")
      return
    }
    capture = .running(sink, engine)
  }

  private func stop() {
    switch capture {
    case .idle:
      return
    case .running(_, let engine):
      tearDown(engine)
    case .interrupted:
      break
    }
    deactivateSession()
    capture = .idle
  }

  private func fail(_ sink: FlutterEventSink, _ code: String, _ message: String) {
    deactivateSession()
    capture = .idle
    sink(FlutterError(code: code, message: message, details: nil))
  }

  private func tearDown(_ engine: AVAudioEngine) {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  private func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch (type, capture) {
    case (.began, .running(let sink, let engine)):
      tearDown(engine)
      capture = .interrupted(sink)
    case (.ended, .interrupted(let sink)):
      start(sink)
    default:
      break
    }
  }

  // The engine stops itself when the hardware sample rate or channel count changes.
  private func configurationChange(_ note: Notification) {
    guard case .running(let sink, let engine) = capture, note.object as AnyObject? === engine
    else { return }
    tearDown(engine)
    start(sink)
  }
}
