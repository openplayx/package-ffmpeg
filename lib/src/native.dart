import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'models.dart';

/// Fixed-layout event snapshot (`opx_media_event` in opx_media.h).
final class OpxEvent extends Struct {
  @Int32()
  external int state;
  @Int32()
  external int error;
  @Int64()
  external int processedUs;
  @Int64()
  external int totalUs;
  @Int64()
  external int sequence;
}

final class OpxJob extends Opaque {}

const supportedAbi = 1;

/// Hand-written bindings for the package's own stable C ABI. FFmpeg types
/// never appear here. One instance per isolate (pointers are per process,
/// function lookups are per isolate).
class MediaNative {
  MediaNative._(DynamicLibrary lib)
    : abiVersion = lib.lookupFunction<Uint32 Function(), int Function()>(
        'opx_media_abi_version',
      ),
      capabilities = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'opx_media_capabilities',
          ),
      probe = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
            int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)
          >('opx_media_probe'),
      stringFree = lib
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('opx_media_string_free'),
      jobCreate = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Pointer<OpxJob>>),
            int Function(Pointer<Utf8>, Pointer<Pointer<OpxJob>>)
          >('opx_media_job_create'),
      jobStart = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxJob>),
            int Function(Pointer<OpxJob>)
          >('opx_media_job_start'),
      jobPoll = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxJob>, Pointer<OpxEvent>),
            int Function(Pointer<OpxJob>, Pointer<OpxEvent>)
          >('opx_media_job_poll'),
      jobCancel = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxJob>),
            int Function(Pointer<OpxJob>)
          >('opx_media_job_cancel'),
      jobJoin = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxJob>),
            int Function(Pointer<OpxJob>)
          >('opx_media_job_join'),
      jobDestroy = lib
          .lookupFunction<
            Void Function(Pointer<OpxJob>),
            void Function(Pointer<OpxJob>)
          >('opx_media_job_destroy');

  final int Function() abiVersion;
  final Pointer<Utf8> Function() capabilities;
  final int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>) probe;
  final void Function(Pointer<Utf8>) stringFree;
  final int Function(Pointer<Utf8>, Pointer<Pointer<OpxJob>>) jobCreate;
  final int Function(Pointer<OpxJob>) jobStart;
  final int Function(Pointer<OpxJob>, Pointer<OpxEvent>) jobPoll;
  final int Function(Pointer<OpxJob>) jobCancel;
  final int Function(Pointer<OpxJob>) jobJoin;
  final void Function(Pointer<OpxJob>) jobDestroy;

  /// Overrides the library location (host tests load a locally built one).
  static String? libraryPath = Platform.environment['OPX_FFMPEG_LIBRARY'];

  static MediaNative? _instance;
  static Object? _loadError;

  /// Throws [MediaException] with [MediaErrorCode.unavailable] when this
  /// build carries no compatible bridge.
  static MediaNative load({String? path}) {
    final cached = _instance;
    if (cached != null) return cached;
    if (_loadError != null) {
      throw const MediaException(MediaErrorCode.unavailable);
    }
    try {
      final native = MediaNative._(_open(path ?? libraryPath));
      if (native.abiVersion() != supportedAbi) {
        throw const MediaException(MediaErrorCode.unavailable);
      }
      return _instance = native;
    } catch (e) {
      _loadError = e;
      throw const MediaException(MediaErrorCode.unavailable);
    }
  }

  static DynamicLibrary _open(String? path) {
    if (path != null && path.isNotEmpty) return DynamicLibrary.open(path);
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.open('openplayx_ffmpeg.framework/openplayx_ffmpeg');
    }
    if (Platform.isWindows) return DynamicLibrary.open('openplayx_ffmpeg.dll');
    return DynamicLibrary.open('libopenplayx_ffmpeg.so');
  }

  String? takeString(Pointer<Utf8> value) {
    if (value == nullptr) return null;
    try {
      return value.toDartString();
    } finally {
      stringFree(value);
    }
  }

  /// Blocking; call from a worker isolate.
  Map<String, dynamic> capabilitiesSync() {
    final text = takeString(capabilities());
    if (text == null) throw const MediaException(MediaErrorCode.nativeFailure);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Blocking; call from a worker isolate. The native deadline (not a Dart
  /// timer) bounds the work, so timing out really stops the I/O.
  Map<String, dynamic> probeSync(String input, int timeoutMs) {
    final request = jsonEncode({'input': input, 'timeout_ms': timeoutMs})
        .toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      final code = probe(request, out);
      if (code != 0) throw MediaException(MediaErrorCode.fromNative(code));
      final text = takeString(out.value);
      if (text == null) {
        throw const MediaException(MediaErrorCode.nativeFailure);
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(request);
      calloc.free(out);
    }
  }
}
