// Unit test for the recorder's per-platform encoding config — #11's headline
// requirement (Opus ~16 kbps mono, with the AAC-LC iOS fallback). Pure: the
// platform is injected, so both branches are deterministic on any host.
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:traccar_client/audio_recorder_service.dart';

void main() {
  group('AudioRecorderService.configFor', () {
    test('Android → Opus ~16 kbps mono, Ogg', () {
      final (config, ext, mime) = AudioRecorderService.configFor(isIOS: false);
      expect(config.encoder, AudioEncoder.opus);
      expect(config.bitRate, 16000);
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1); // mono
      expect(ext, 'ogg');
      expect(mime, 'audio/ogg; codecs=opus');
    });

    test('iOS → AAC-LC ~32 kbps mono, m4a (Opus/Ogg unsupported)', () {
      final (config, ext, mime) = AudioRecorderService.configFor(isIOS: true);
      expect(config.encoder, AudioEncoder.aacLc);
      expect(config.bitRate, 32000);
      expect(config.sampleRate, 22050);
      expect(config.numChannels, 1); // mono
      expect(ext, 'm4a');
      expect(mime, 'audio/mp4');
    });
  });
}
