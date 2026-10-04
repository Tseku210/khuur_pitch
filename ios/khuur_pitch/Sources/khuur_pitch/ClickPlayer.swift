import AVFoundation
import Flutter

/// The metronome's clicks. Each beat is a short buffer scheduled on the
/// player's own sample clock a little ahead of time, so the beats are as even
/// as the audio hardware and no timer's lateness is heard.
///
/// `khuur_pitch/click` takes `configure(bpm, beatsPerBar)`. Listening to
/// `khuur_pitch/beats` starts the clicks and cancelling stops them, and each
/// event is the place in the bar of the beat that sounds now.
final class ClickPlayer: NSObject, FlutterStreamHandler {
  private struct Playing {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    let accent: AVAudioPCMBuffer
    let plain: AVAudioPCMBuffer
    let timer: DispatchSourceTimer
    let run: Int
    let sink: FlutterEventSink
    /// How long a frame handed to the output takes to be heard, in seconds.
    let latency: Double
    var beat = 0
    /// Where the last beat went on the player's clock, in frames. The next
    /// one is placed from it at the tempo of the moment, so a new tempo
    /// takes hold on the very next beat.
    var last: Double
  }

  /// How far ahead a beat is handed to the player. The fastest tempo puts
  /// beats 250 ms apart, so at most one waits there for a tempo change.
  private static let horizon = 0.2
  private static let clickSeconds = 0.05

  /// Owns the tempo, the bar length and `playing`.
  private let queue = DispatchQueue(label: "khuur_pitch.click", qos: .userInteractive)
  private var bpm = 80.0
  private var beatsPerBar = 4
  private var playing: Playing?

  /// The run whose beats may still reach Dart. Main thread only.
  private var live: (run: Int, sink: FlutterEventSink)?
  private var runs = 0
  private var observers: [NSObjectProtocol] = []

  override init() {
    super.init()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak self] note in
        let began = AVAudioSession.InterruptionType.began.rawValue
        if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == began { self?.end() }
      },
      // The engine stops itself when the output route changes.
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
      ) { [weak self] note in
        guard let self else { return }
        let ours = self.queue.sync { self.playing?.engine === note.object as AnyObject? }
        if ours { self.end() }
      },
    ]
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "configure" else { return result(FlutterMethodNotImplemented) }
    guard let args = call.arguments as? [String: Any],
      let bpm = args["bpm"] as? Int, bpm > 0,
      let beatsPerBar = args["beatsPerBar"] as? Int, beatsPerBar > 0
    else {
      return result(FlutterError(code: "badArguments", message: "\(call.arguments ?? "nil")", details: nil))
    }
    queue.async {
      self.bpm = Double(bpm)
      if beatsPerBar != self.beatsPerBar {
        self.beatsPerBar = beatsPerBar
        self.playing?.beat = 0
      }
    }
    result(nil)
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    stop()
    // A failure goes down the sink. One returned from here would fail the
    // listen call, which Dart reports and keeps from the stream.
    let session = AVAudioSession.sharedInstance()
    do {
      // Playback, so the clicks sound with the ring switch off.
      try session.setCategory(.playback)
      try session.setActive(true)
    } catch {
      events(
        FlutterError(
          code: "audioFailed", message: "Audio session: \(error.localizedDescription)", details: nil))
      return nil
    }
    runs += 1
    let run = runs
    let latency = session.outputLatency
    if let failure = queue.sync(execute: { start(run: run, sink: events, latency: latency) }) {
      deactivateSession()
      events(FlutterError(code: "audioFailed", message: failure, details: nil))
      return nil
    }
    live = (run, events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    return nil
  }

  func stop() {
    guard live != nil else { return }
    live = nil
    queue.sync {
      guard let playing else { return }
      playing.timer.cancel()
      playing.player.stop()
      playing.engine.stop()
      self.playing = nil
    }
    deactivateSession()
  }

  /// Stops because the OS took the audio, and tells Dart the clicks are over.
  private func end() {
    guard let sink = live?.sink else { return }
    stop()
    sink(FlutterEndOfEventStream)
  }

  private func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// On `queue`. Returns what went wrong, or nil once the clicks run.
  private func start(run: Int, sink: @escaping FlutterEventSink, latency: Double) -> String? {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let hardware = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: hardware > 0 ? hardware : 44100, channels: 1),
      let accent = Self.click(format, hz: 1760, gain: 0.9),
      let plain = Self.click(format, hz: 1175, gain: 0.6)
    else { return "No audio output format" }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    do {
      engine.prepare()
      try engine.start()
    } catch {
      return "Audio engine: \(error.localizedDescription)"
    }
    player.play()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.fill() }
    // The first beat lands 100 ms in, one beat after a `last` that never was.
    playing = Playing(
      engine: engine, player: player, accent: accent, plain: plain, timer: timer, run: run,
      sink: sink, latency: latency, last: format.sampleRate * (0.1 - 60 / bpm))
    timer.resume()
    return nil
  }

  /// On `queue`. Hands the player every beat that falls inside the horizon.
  private func fill() {
    guard var playing,
      let node = playing.player.lastRenderTime, node.isSampleTimeValid,
      let now = playing.player.playerTime(forNodeTime: node)
    else { return }
    let rate = now.sampleRate
    let current = Double(now.sampleTime)
    while true {
      // After a stall the missed beats are dropped, not played in a burst.
      let next = max(playing.last + rate * 60 / bpm, current)
      guard next < current + rate * Self.horizon else { break }
      let frame = AVAudioFramePosition(next.rounded())
      playing.player.scheduleBuffer(
        playing.beat % beatsPerBar == 0 ? playing.accent : playing.plain,
        at: AVAudioTime(sampleTime: frame, atRate: rate))
      let beat = playing.beat % beatsPerBar
      let run = playing.run
      let sink = playing.sink
      let heard = (next - current) / rate + playing.latency
      DispatchQueue.main.asyncAfter(deadline: .now() + heard) { [weak self] in
        if self?.live?.run == run { sink(beat) }
      }
      playing.last = next
      playing.beat = (beat + 1) % beatsPerBar
    }
    self.playing = playing
  }

  /// A sine that dies away in a few milliseconds, which reads as a tick.
  private static func click(_ format: AVAudioFormat, hz: Double, gain: Double) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(format.sampleRate * clickSeconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let samples = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = frames
    for n in 0..<Int(frames) {
      let t = Double(n) / format.sampleRate
      samples[n] = Float(gain * sin(2 * .pi * hz * t) * exp(-t / 0.008))
    }
    return buffer
  }
}
