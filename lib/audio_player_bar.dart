import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Reusable audio player row (design screens 08/05-review). The source is
/// resolved lazily on first play via [resolve] — a callback that fetches +
/// decodes the report audio to a local file path (GET /visit/report/{id}/audio),
/// or returns null when audio is unavailable. Nothing is downloaded until the
/// user taps play, honouring "audio is streamed on demand, never eagerly
/// list-selected".
class AudioPlayerBar extends StatefulWidget {
  /// Resolves the playable local file path, or null when unavailable. Called at
  /// most once (the result is held for the life of the widget).
  final Future<String?> Function() resolve;

  const AudioPlayerBar({super.key, required this.resolve});

  @override
  State<AudioPlayerBar> createState() => _AudioPlayerBarState();
}

enum _Load { idle, loading, ready, failed }

class _AudioPlayerBarState extends State<AudioPlayerBar> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;
  _Load _load = _Load.idle;

  @override
  void initState() {
    super.initState();
    // The source is fetched on first play, but wire the streams now so playback
    // state is reflected the instant a source is set.
    _posSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      } else {
        setState(() => _playing = s.playing);
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// First tap resolves + loads the source, then plays; later taps toggle. A
  /// prior failure is retryable: a transient fetch error (offline) must not
  /// disable playback for the life of the screen, so a failed tap re-resolves.
  Future<void> _toggle() async {
    switch (_load) {
      case _Load.loading:
        return; // in flight
      case _Load.idle:
      case _Load.failed:
        await _loadThenPlay();
      case _Load.ready:
        await _playPause();
    }
  }

  Future<void> _loadThenPlay() async {
    setState(() => _load = _Load.loading);
    try {
      final path = await widget.resolve();
      if (!mounted) return;
      if (path == null) {
        setState(() => _load = _Load.failed);
        return;
      }
      _total = await _player.setFilePath(path) ?? Duration.zero;
      if (!mounted) return;
      setState(() => _load = _Load.ready);
      await _player.play();
    } catch (_) {
      // Fetch/decode/load failed — mark failed but keep the button tappable.
      // Unlike a bundled-asset failure (permanent), a network fetch can succeed
      // on a later retry once connectivity returns; _toggle re-resolves from here.
      if (mounted) setState(() => _load = _Load.failed);
    }
  }

  Future<void> _playPause() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        if (_total > Duration.zero && _pos >= _total) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = _total.inMilliseconds;
    final posMs = _pos.inMilliseconds.clamp(0, totalMs == 0 ? 0 : totalMs);
    final timeStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final loading = _load == _Load.loading;
    // Disabled only while a load is in flight; idle/ready/failed all stay
    // tappable so a failed fetch can be retried once back online.
    final enabled = !loading;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: enabled ? _toggle : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.4),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: totalMs == 0 ? 0 : posMs.toDouble(),
                      max: totalMs == 0 ? 1 : totalMs.toDouble(),
                      onChanged: totalMs == 0
                          ? null
                          : (v) => _player.seek(
                              Duration(milliseconds: v.round()),
                            ),
                    ),
                  ),
                  Padding(
                    // Align the times with the slider's track ends.
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(_pos), style: timeStyle),
                        Text(_fmt(_total), style: timeStyle),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
