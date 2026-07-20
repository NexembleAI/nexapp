import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Reusable audio player row (design screens 08/05-review). Plays a bundled
/// asset for now; the source becomes GET /visit/report/{id}/audio later.
class AudioPlayerBar extends StatefulWidget {
  final String assetPath;

  const AudioPlayerBar({super.key, required this.assetPath});

  @override
  State<AudioPlayerBar> createState() => _AudioPlayerBarState();
}

class _AudioPlayerBarState extends State<AudioPlayerBar> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;
  bool _ready = false; // true once setAsset resolves; gates the play button

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _total = await _player.setAsset(widget.assetPath) ?? Duration.zero;
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // Leave _ready false so the button stays disabled instead of throwing on
      // tap. (When the source becomes GET …/audio, this is also the "audio
      // unavailable" state.)
    }
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

  Future<void> _toggle() async {
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
      // play()/pause() can throw if the source errored (e.g. a network source
      // that failed after load). Don't surface it unhandled or wedge the icon.
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: _ready ? _toggle : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _ready
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.4),
                ),
                child: Icon(
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
