import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'native.dart';
import 'presets.dart';

/// App-facing entry point: probe, plan and run jobs on the in-process
/// FFmpeg bridge. Jobs run one at a time on native worker threads; the UI
/// isolate only performs non-blocking polls.
///
/// Inputs must be absolute local paths or host-owned loopback URLs (e.g. a
/// session stream gateway); the native layer rejects anything else and
/// blocks secondary opens. Outputs go to a `.part` file that is validated
/// before being renamed into place.
class MediaProcessor {
  MediaProcessor({
    String? libraryPath,
    this.pollInterval = const Duration(milliseconds: 150),
  }) : _libraryPath = libraryPath ?? MediaNative.libraryPath;

  final String? _libraryPath;
  final Duration pollInterval;
  final _queue = Queue<MediaJob>();
  MediaJob? _running;
  Future<MediaCapabilities>? _capabilities;
  bool _disposed = false;

  MediaNative get _native => MediaNative.load(path: _libraryPath);

  /// Whether the bridge library loads in this build.
  bool get available {
    try {
      _native;
      return true;
    } on MediaException {
      return false;
    }
  }

  /// Measured once per process (opening hardware encoders takes time).
  Future<MediaCapabilities> capabilities() => _capabilities ??= () async {
    if (!available) return const MediaCapabilities.unavailable();
    final path = _libraryPath;
    try {
      final json = await Isolate.run(
        () => MediaNative.load(path: path).capabilitiesSync(),
      );
      return MediaCapabilities.fromJson(json);
    } catch (_) {
      return const MediaCapabilities.unavailable();
    }
  }();

  /// Bounded probe on a worker isolate; the native deadline stops the I/O
  /// when [timeout] passes.
  Future<MediaProbe> probe(
    String input, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _native; // throws unavailable early
    final path = _libraryPath;
    final ms = timeout.inMilliseconds.clamp(100, 120000);
    try {
      final json = await Isolate.run(
        () => MediaNative.load(path: path).probeSync(input, ms),
      );
      return MediaProbe.fromJson(json);
    } on MediaException {
      rethrow;
    } on RemoteError {
      throw const MediaException(MediaErrorCode.nativeFailure);
    }
  }

  /// Queues a job. [output] is the final path; it is only created after
  /// the result validated. Existing files are never overwritten.
  MediaJob submit(
    MediaPlan plan, {
    required String input,
    required String output,
  }) {
    if (_disposed) throw StateError('disposed');
    final job = MediaJob._(this, plan, input, output);
    _queue.add(job);
    _pump();
    return job;
  }

  void _pump() {
    if (_running != null || _queue.isEmpty || _disposed) return;
    final job = _running = _queue.removeFirst();
    unawaited(
      job._run().whenComplete(() {
        _running = null;
        _pump();
      }),
    );
  }

  void _dequeue(MediaJob job) => _queue.remove(job);

  /// Requests cancellation of every job; native work stops cooperatively.
  void dispose() {
    _disposed = true;
    for (final job in [..._queue]) {
      job.cancel();
    }
    _running?.cancel();
  }
}

class MediaJob {
  MediaJob._(this._processor, this.plan, this._input, this.output);
  final MediaProcessor _processor;
  final MediaPlan plan;
  final String _input;
  final String output;
  final _progress = StreamController<MediaJobProgress>.broadcast();
  final _done = Completer<MediaJobResult>();
  MediaJobProgress _last = const MediaJobProgress(MediaJobState.queued);
  bool _cancelRequested = false;
  Pointer<OpxJob>? _handle;

  Stream<MediaJobProgress> get progress => _progress.stream;
  MediaJobProgress get current => _last;
  Future<MediaJobResult> get done => _done.future;

  /// Cooperative cancel. Until native work observes it the state stays
  /// `cancelling`; it never reports cancelled while still running.
  void cancel() {
    if (_cancelRequested || _last.state.terminal) return;
    _cancelRequested = true;
    final handle = _handle;
    if (handle == null) {
      _processor._dequeue(this);
      _finish(
        const MediaJobResult(
          MediaJobState.cancelled,
          error: MediaErrorCode.cancelled,
        ),
      );
      return;
    }
    _processor._native.jobCancel(handle);
    _emit(
      MediaJobProgress(
        MediaJobState.cancelling,
        processed: _last.processed,
        total: _last.total,
      ),
    );
  }

  void _emit(MediaJobProgress p) {
    _last = p;
    if (!_progress.isClosed) _progress.add(p);
  }

  void _finish(MediaJobResult result) {
    if (_done.isCompleted) return;
    _emit(
      MediaJobProgress(
        result.state,
        processed: _last.processed,
        total: _last.total,
        error: result.error,
      ),
    );
    _done.complete(result);
    unawaited(_progress.close());
  }

  String get _part => '$output.part';

  Future<void> _run() async {
    if (_done.isCompleted) return;
    if (File(output).existsSync()) {
      return _finish(
        const MediaJobResult(
          MediaJobState.failed,
          error: MediaErrorCode.invalidArgument,
        ),
      );
    }
    final native = _processor._native;
    final planJson = jsonEncode(plan.bind(_input, _part)).toNativeUtf8();
    final out = calloc<Pointer<OpxJob>>();
    final event = calloc<OpxEvent>();
    Pointer<OpxJob>? handle;
    try {
      await Directory(File(output).parent.path).create(recursive: true);
      final created = native.jobCreate(planJson, out);
      if (created != 0) {
        return _finish(
          MediaJobResult(
            MediaJobState.failed,
            error: MediaErrorCode.fromNative(created),
          ),
        );
      }
      handle = _handle = out.value;
      if (native.jobStart(handle) != 0) {
        return _finish(
          const MediaJobResult(
            MediaJobState.failed,
            error: MediaErrorCode.nativeFailure,
          ),
        );
      }
      if (_cancelRequested) native.jobCancel(handle);
      var state = MediaJobState.queued;
      while (true) {
        final changed = native.jobPoll(handle, event);
        if (changed > 0) {
          state = MediaJobState.fromNative(event.ref.state);
          final total = event.ref.totalUs;
          final p = MediaJobProgress(
            _cancelRequested && !state.terminal
                ? MediaJobState.cancelling
                : state,
            processed: Duration(microseconds: event.ref.processedUs),
            total: total > 0 ? Duration(microseconds: total) : null,
          );
          if (!state.terminal) _emit(p);
          if (state.terminal) {
            _last = p;
            break;
          }
        }
        await Future<void>.delayed(_processor.pollInterval);
      }
      // Terminal state means the worker returned; join is immediate.
      native.jobJoin(handle);
      if (state != MediaJobState.succeeded) {
        _deletePart();
        return _finish(
          MediaJobResult(
            state,
            error: MediaErrorCode.fromNative(event.ref.error),
          ),
        );
      }
      final valid = await _validate();
      if (valid != null) {
        _deletePart();
        return _finish(MediaJobResult(MediaJobState.failed, error: valid));
      }
      final file = await File(_part).rename(output);
      _finish(
        MediaJobResult(
          MediaJobState.succeeded,
          outputPath: file.path,
          bytes: await file.length(),
        ),
      );
    } catch (_) {
      final h = handle;
      if (h != null) native.jobCancel(h);
      _deletePart();
      _finish(
        const MediaJobResult(
          MediaJobState.failed,
          error: MediaErrorCode.nativeFailure,
        ),
      );
    } finally {
      if (handle != null) {
        native.jobJoin(handle);
        native.jobDestroy(handle);
      }
      _handle = null;
      calloc.free(planJson);
      calloc.free(out);
      calloc.free(event);
    }
  }

  void _deletePart() {
    try {
      final f = File(_part);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// A finished native job is not trusted blindly: the output must be
  /// non-empty and, for media files, re-probe with the expected tracks.
  Future<MediaErrorCode?> _validate() async {
    final f = File(_part);
    if (!f.existsSync() || f.lengthSync() == 0) {
      return MediaErrorCode.nativeFailure;
    }
    final expects = plan.expects;
    if (expects == null) return null;
    try {
      final probe = await _processor.probe(
        _part,
        timeout: const Duration(seconds: 20),
      );
      for (final type in expects) {
        if (!probe.streams.any((s) => s.type == type)) {
          return MediaErrorCode.nativeFailure;
        }
      }
      return null;
    } on MediaException {
      return MediaErrorCode.nativeFailure;
    }
  }
}
