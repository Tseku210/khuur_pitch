package com.khuur.khuur_pitch

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Process
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/**
 * The metronome's clicks. One thread writes the track sample by sample and
 * counts frames between beats, so the beats are as even as the audio clock.
 *
 * `khuur_pitch/click` takes `configure(bpm, beatsPerBar)`. Listening to
 * `khuur_pitch/beats` starts the clicks and cancelling stops them, and each
 * event is the place in the bar of the beat that sounds now.
 */
internal class ClickPlayer(private val main: Handler) :
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler {

  @Volatile private var bpm = 80
  @Volatile private var beatsPerBar = 4
  @Volatile private var restartBar = false
  private var playing: Playing? = null

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "configure") return result.notImplemented()
    val bpm = call.argument<Int>("bpm")
    val beatsPerBar = call.argument<Int>("beatsPerBar")
    if (bpm == null || bpm <= 0 || beatsPerBar == null || beatsPerBar <= 0) {
      return result.error("badArguments", "${call.arguments}", null)
    }
    this.bpm = bpm
    if (beatsPerBar != this.beatsPerBar) {
      this.beatsPerBar = beatsPerBar
      restartBar = true
    }
    result.success(null)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    stop()
    val track = open()
    if (track == null) {
      events.error("audioFailed", "AudioTrack could not be opened", null)
      return
    }
    restartBar = false
    playing = Playing(track, events).also { it.start() }
  }

  override fun onCancel(arguments: Any?) = stop()

  fun stop() {
    playing?.stop()
    playing = null
  }

  private fun open(): AudioTrack? {
    val rate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC)
    val minBytes = AudioTrack.getMinBufferSize(rate, CHANNEL, ENCODING)
    if (minBytes <= 0) return null
    val track = try {
      AudioTrack.Builder()
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build(),
        )
        .setAudioFormat(
          AudioFormat.Builder()
            .setEncoding(ENCODING)
            .setSampleRate(rate)
            .setChannelMask(CHANNEL)
            .build(),
        )
        // Room for the writer to be late without a gap in the sound.
        .setBufferSizeInBytes(minBytes * 2)
        .setTransferMode(AudioTrack.MODE_STREAM)
        .build()
    } catch (e: UnsupportedOperationException) {
      return null
    } catch (e: IllegalArgumentException) {
      return null
    }
    if (track.state == AudioTrack.STATE_INITIALIZED) return track
    track.release()
    return null
  }

  private inner class Playing(
    private val track: AudioTrack,
    private val events: EventChannel.EventSink,
  ) {
    @Volatile private var running = true
    private val rate = track.sampleRate
    private val thread = Thread({ writeLoop() }, "khuur_pitch click")

    fun start() {
      track.play()
      thread.start()
    }

    fun stop() {
      running = false
      // The track keeps draining while it plays, so a blocked write returns.
      thread.join()
      track.pause()
      track.flush()
      track.release()
    }

    private fun writeLoop() {
      Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
      val block = FloatArray(BLOCK_FRAMES)
      val clickFrames = (rate * CLICK_SECONDS).toInt()
      // A written frame sounds once the frames buffered ahead of it have.
      val bufferedMs = track.bufferSizeInFrames * 1000L / rate
      // Frames since the last beat, counted against the tempo of the moment
      // so a new tempo takes hold on the very next beat.
      var sinceBeat = Double.MAX_VALUE
      var beat = 0
      var age = clickFrames
      var accent = false
      while (running) {
        for (i in block.indices) {
          if (sinceBeat >= rate * 60.0 / bpm) {
            if (restartBar) {
              restartBar = false
              beat = 0
            }
            beat %= beatsPerBar
            accent = beat == 0
            age = 0
            val sounding = beat
            main.postDelayed(
              { if (playing === this) events.success(sounding) },
              bufferedMs + i * 1000L / rate,
            )
            sinceBeat = if (sinceBeat == Double.MAX_VALUE) 0.0 else sinceBeat - rate * 60.0 / bpm
            beat++
          }
          block[i] = if (age < clickFrames) sample(age++, accent) else 0f
          sinceBeat += 1.0
        }
        val written = track.write(block, 0, block.size, AudioTrack.WRITE_BLOCKING)
        if (written < 0) {
          main.post {
            if (playing === this) {
              events.error("audioFailed", "AudioTrack.write returned $written", null)
              this@ClickPlayer.stop()
            }
          }
          return
        }
      }
    }

    /** A sine that dies away in a few milliseconds, which reads as a tick. */
    private fun sample(age: Int, accent: Boolean): Float {
      val t = age.toDouble() / rate
      val hz = if (accent) 1760.0 else 1175.0
      val gain = if (accent) 0.9 else 0.6
      return (gain * sin(2 * PI * hz * t) * exp(-t / 0.008)).toFloat()
    }
  }

  private companion object {
    const val BLOCK_FRAMES = 256
    const val CLICK_SECONDS = 0.05
    const val CHANNEL = AudioFormat.CHANNEL_OUT_MONO
    const val ENCODING = AudioFormat.ENCODING_PCM_FLOAT
  }
}
