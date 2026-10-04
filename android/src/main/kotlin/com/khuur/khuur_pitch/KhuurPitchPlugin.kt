package com.khuur.khuur_pitch

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class KhuurPitchPlugin :
  FlutterPlugin,
  ActivityAware,
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler,
  PluginRegistry.RequestPermissionsResultListener {

  private enum class MicPermission { granted, denied, permanentlyDenied }

  private val main = Handler(Looper.getMainLooper())
  private lateinit var context: Context
  private lateinit var control: MethodChannel
  private lateinit var audio: EventChannel
  private var activity: ActivityPluginBinding? = null
  private var pendingRequest: MethodChannel.Result? = null
  private var capture: Capture? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    control = MethodChannel(binding.binaryMessenger, "khuur_pitch/control")
    control.setMethodCallHandler(this)
    audio = EventChannel(binding.binaryMessenger, "khuur_pitch/audio")
    audio.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopCapture()
    control.setMethodCallHandler(null)
    audio.setStreamHandler(null)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivityForConfigChanges() = unbindActivity()

  override fun onDetachedFromActivity() {
    unbindActivity()
    pendingRequest?.success(MicPermission.denied.name)
    pendingRequest = null
  }

  private fun unbindActivity() {
    activity?.removeRequestPermissionsResultListener(this)
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "checkPermission" ->
        result.success((if (hasPermission()) MicPermission.granted else MicPermission.denied).name)
      "requestPermission" -> requestPermission(result)
      "openAppSettings" -> {
        openAppSettings()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun hasPermission() =
    context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

  private fun requestPermission(result: MethodChannel.Result) {
    val activity = activity?.activity
    when {
      hasPermission() -> result.success(MicPermission.granted.name)
      activity == null -> result.error("noActivity", "Requesting a permission needs an activity", null)
      pendingRequest != null ->
        result.error("alreadyRequesting", "A microphone permission request is in progress", null)
      else -> {
        pendingRequest = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
      }
    }
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ): Boolean {
    if (requestCode != PERMISSION_REQUEST) return false
    val result = pendingRequest ?: return true
    pendingRequest = null
    val rationale = activity?.activity?.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
    val answer = when {
      grantResults.isEmpty() -> MicPermission.denied
      grantResults[0] == PackageManager.PERMISSION_GRANTED -> MicPermission.granted
      // After a denial, no rationale means the OS will not show the dialog again.
      rationale == false -> MicPermission.permanentlyDenied
      else -> MicPermission.denied
    }
    result.success(answer.name)
    return true
  }

  private fun openAppSettings() {
    val intent = Intent(
      Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
      Uri.fromParts("package", context.packageName, null),
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    stopCapture()
    if (!hasPermission()) {
      events.error("permissionDenied", "Microphone access is not granted", null)
      return
    }
    val record = openRecord()
    if (record == null) {
      events.error("noInput", "AudioRecord accepts none of $SAMPLE_RATES Hz", null)
      return
    }
    val startError = try {
      record.startRecording()
      if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) null
      else "recording state is ${record.recordingState}"
    } catch (e: IllegalStateException) {
      e.message ?: e.toString()
    }
    if (startError != null) {
      record.release()
      events.error("audioFailed", "AudioRecord.startRecording: $startError", null)
      return
    }
    capture = Capture(record, events).also { it.start() }
  }

  override fun onCancel(arguments: Any?) = stopCapture()

  private fun stopCapture() {
    capture?.stop()
    capture = null
  }

  @SuppressLint("MissingPermission")
  private fun openRecord(): AudioRecord? {
    val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    // UNPROCESSED silently falls back to the AGC-processed default source where unsupported.
    val unprocessed =
      audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
    val source =
      if (unprocessed) MediaRecorder.AudioSource.UNPROCESSED
      else MediaRecorder.AudioSource.VOICE_RECOGNITION
    for (rate in SAMPLE_RATES) {
      val minBytes = AudioRecord.getMinBufferSize(rate, CHANNEL, ENCODING)
      if (minBytes <= 0) continue
      val bytes = maxOf(minBytes, CHUNK_FRAMES * Float.SIZE_BYTES) * BUFFER_HEADROOM
      val record = try {
        AudioRecord(source, rate, CHANNEL, ENCODING, bytes)
      } catch (e: IllegalArgumentException) {
        continue
      }
      if (record.state == AudioRecord.STATE_INITIALIZED) return record
      record.release()
    }
    return null
  }

  private inner class Capture(
    private val record: AudioRecord,
    private val events: EventChannel.EventSink,
  ) {
    @Volatile private var running = true
    private val sampleRate = record.sampleRate
    private val thread = Thread({ readLoop() }, "khuur_pitch capture")

    fun start() = thread.start()

    fun stop() {
      running = false
      // stop() releases a blocked read; the join keeps read off the released record.
      record.stop()
      thread.join()
      record.release()
    }

    private fun readLoop() {
      val buffer = FloatArray(CHUNK_FRAMES)
      while (running) {
        val n = record.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
        if (n > 0) {
          val chunk = mapOf("sampleRate" to sampleRate, "samples" to buffer.copyOf(n))
          main.post { if (capture === this@Capture) events.success(chunk) }
        } else if (n < 0) {
          main.post {
            if (capture === this@Capture) {
              events.error("audioFailed", "AudioRecord.read returned $n", null)
              stopCapture()
            }
          }
          return
        }
      }
    }
  }

  private companion object {
    const val PERMISSION_REQUEST = 0x6b70
    const val CHUNK_FRAMES = 1024
    const val BUFFER_HEADROOM = 4
    val CHANNEL = AudioFormat.CHANNEL_IN_MONO
    val ENCODING = AudioFormat.ENCODING_PCM_FLOAT
    val SAMPLE_RATES = listOf(48000, 44100)
  }
}
