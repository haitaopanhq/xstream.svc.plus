import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xconnect/bindings/bridge_bindings.dart';
import 'package:xconnect/utils/native_bridge.dart';

void main() {
  group('NativeBridge macOS library candidates', () {
    test('resolves expected framework and packet tunnel paths', () {
      const mockExec = '/Applications/xconnect.app/Contents/MacOS/xconnect';
      final candidates =
          NativeBridge.getMacOSLibraryCandidates(executablePath: mockExec);

      expect(candidates, contains('libxray_bridge.dylib'));
      expect(
        candidates,
        contains('/Applications/xconnect.app/Contents/Frameworks/libxray_bridge.dylib'),
      );
      expect(
        candidates,
        contains(
          '/Applications/xconnect.app/Contents/PlugIns/PacketTunnel.appex/Contents/Frameworks/libxray_bridge.dylib',
        ),
      );
    });
  });

  group('BridgeBindings optional symbols', () {
    test('handles missing InitTray gracefully without throwing on instantiation',
        () {
      // libxray_bridge.dylib on macOS does not export InitTray (only Linux/Windows do).
      // Verify that if a dylib exists at the PacketTunnel path, BridgeBindings loads it.
      const candidatePath =
          '/Applications/xconnect.app/Contents/PlugIns/PacketTunnel.appex/Contents/Frameworks/libxray_bridge.dylib';
      if (!File(candidatePath).existsSync()) {
        return;
      }

      final dylib = ffi.DynamicLibrary.open(candidatePath);
      final bindings = BridgeBindings(dylib);

      expect(bindings.initTray, isNull);
      expect(bindings.startXray, isNotNull);
      expect(bindings.stopXray, isNotNull);
      expect(bindings.freeCString, isNotNull);
    });
  });
}
