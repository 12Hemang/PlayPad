import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ble/gamepad/controller_factory.dart';
import 'package:ble/gamepad/n64_gamepad_controller.dart';
import 'package:ble/gamepad/nes_gamepad_controller.dart';
import 'package:ble/hid/ble_logger.dart';
import 'package:ble/hid/permission_service.dart';
import 'package:ble/models/controller_layout.dart';
import 'package:ble/models/haptic_settings.dart';
import 'package:ble/screens/controller_edit_screen.dart';
import 'package:ble/server/rom_server.dart';
import 'package:ble/server/tv_pusher_service.dart';

void main() {
  group('NES Gamepad Controller Tests', () {
    test('Initial state is neutral', () {
      final controller = NesGamepadController();
      final report = controller.buildReport();

      // [X, Y, Hat, ButtonsLow, ButtonsHigh]
      expect(report.length, 5);
      expect(report[0], 128); // X neutral
      expect(report[1], 128); // Y neutral
      expect(report[2], 0);   // Hat centered
      expect(report[3], 0);   // Buttons released
      expect(report[4], 0);
    });

    test('D-Pad directions calculate correct X/Y and Hat switch', () {
      final controller = NesGamepadController();

      // Test UP
      controller.pressButton(NesButton.up);
      var report = controller.buildReport();
      expect(report[1], 0);   // Y up
      expect(report[2], 1);   // Hat up

      controller.releaseButton(NesButton.up);
      report = controller.buildReport();
      expect(report[1], 128);
      expect(report[2], 0);

      // Test RIGHT
      controller.pressButton(NesButton.right);
      report = controller.buildReport();
      expect(report[0], 255); // X right
      expect(report[2], 3);   // Hat right

      controller.reset();
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[2], 0);
    });

    test('Buttons A, B, X, Y, Select, Start set correct bitmask with NES/N64 swap', () {
      final controller = NesGamepadController();

      // Default: swapAB is true (NES & N64 mode: A = Jump = bit 1, B = Run = bit 0)
      expect(controller.swapAB, true);

      // Button A (bit 1 of buttonsLow when swapped)
      controller.pressButton(NesButton.a);
      var report = controller.buildReport();
      expect(report[3] & (1 << 1), isNot(0));
      controller.releaseButton(NesButton.a);

      // Button B (bit 0 of buttonsLow when swapped)
      controller.pressButton(NesButton.b);
      report = controller.buildReport();
      expect(report[3] & (1 << 0), isNot(0));
      controller.releaseButton(NesButton.b);

      // Verify unswapped mode (swapAB = false)
      controller.swapAB = false;
      controller.pressButton(NesButton.a);
      report = controller.buildReport();
      expect(report[3] & (1 << 0), isNot(0));
      controller.releaseButton(NesButton.a);

      controller.pressButton(NesButton.b);
      report = controller.buildReport();
      expect(report[3] & (1 << 1), isNot(0));
      controller.releaseButton(NesButton.b);

      // Restore swapped mode for remaining checks
      controller.swapAB = true;

      // Button X (bit 3 of buttonsLow: KEYCODE_BUTTON_X)
      controller.pressButton(NesButton.x);
      report = controller.buildReport();
      expect(report[3] & (1 << 3), isNot(0));

      // Button Y (bit 4 of buttonsLow: KEYCODE_BUTTON_Y)
      controller.pressButton(NesButton.y);
      report = controller.buildReport();
      expect(report[3] & (1 << 4), isNot(0));

      // Select (bit 2 of buttonsHigh: KEYCODE_BUTTON_SELECT)
      controller.pressButton(NesButton.select);
      report = controller.buildReport();
      expect(report[4] & (1 << 2), isNot(0));

      // Start (bit 3 of buttonsHigh: KEYCODE_BUTTON_START)
      controller.pressButton(NesButton.start);
      report = controller.buildReport();
      expect(report[4] & (1 << 3), isNot(0));

      // Reset
      controller.reset();
      report = controller.buildReport();
      expect(report[3], 0);
      expect(report[4], 0);
    });
  });

  group('ControllerLayout Tests', () {
    test('Default portrait layout has valid coordinates and scale for NES and N64', () {
      final pNes = ControllerLayout.defaultPortrait(controllerType: ControllerType.nes);
      expect(pNes.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(pNes.dpad.dy, inInclusiveRange(0.0, 1.0));
      expect(pNes.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(pNes.menuButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(pNes.dpad.scale, inInclusiveRange(0.6, 2.0));
      expect(pNes.directionType, DirectionControlType.dpad);

      final pN64 = ControllerLayout.defaultPortrait(controllerType: ControllerType.n64);
      expect(pN64.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(pN64.dpad.dy, inInclusiveRange(0.0, 1.0));
      expect(pN64.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(pN64.menuButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(pN64.dpad.scale, inInclusiveRange(0.6, 2.0));
      expect(pN64.directionType, DirectionControlType.joystick);
    });

    test('Default landscape layout has valid coordinates and scale for NES and N64', () {
      final lNes = ControllerLayout.defaultLandscape(controllerType: ControllerType.nes);
      expect(lNes.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(lNes.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(lNes.menuButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(lNes.directionType, DirectionControlType.dpad);

      final lN64 = ControllerLayout.defaultLandscape(controllerType: ControllerType.n64);
      expect(lN64.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(lN64.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(lN64.menuButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(lN64.directionType, DirectionControlType.joystick);
    });

    test('Json serialization round-trip with scale and rotation', () {
      final original = ControllerLayout(
        dpad: const ClusterLayout(dx: 0.25, dy: 0.65, scale: 1.2, rotation: 0.45),
        actionButtons: const ClusterLayout(dx: 0.75, dy: 0.65, scale: 1.4, rotation: -0.3),
        menuButtons: const ClusterLayout(dx: 0.50, dy: 0.85, scale: 0.9, rotation: 0.0),
      );
      final json = original.toJson();
      final restored = ControllerLayout.fromJson(json);

      expect(restored.dpad.dx, closeTo(0.25, 0.001));
      expect(restored.dpad.dy, closeTo(0.65, 0.001));
      expect(restored.dpad.scale, closeTo(1.2, 0.001));
      expect(restored.dpad.rotation, closeTo(0.45, 0.001));
      expect(restored.actionButtons.rotation, closeTo(-0.3, 0.001));
      expect(restored.menuButtons.rotation, closeTo(0.0, 0.001));
    });

    test('ControllerEditResult holds selectedType and layouts', () {
      final res = ControllerEditResult(
        selectedType: ControllerType.n64,
        portraitLayout: ControllerLayout.defaultPortrait(controllerType: ControllerType.n64),
        landscapeLayout: ControllerLayout.defaultLandscape(controllerType: ControllerType.n64),
      );
      expect(res.selectedType, ControllerType.n64);
      expect(res.portraitLayout.directionType, DirectionControlType.joystick);
      expect(res.landscapeLayout.directionType, DirectionControlType.joystick);
    });
  });

  group('BleLogger Tests', () {
    test('Logs are added and formatted correctly', () {
      final logger = BleLogger.instance;
      logger.clear();

      logger.info('TEST', 'Test message');
      expect(logger.history.isNotEmpty, true);
      final last = logger.history.last;
      expect(last.level, 'INFO');
      expect(last.tag, 'TEST');
      expect(last.message, 'Test message');
    });
  });

  group('PermissionStatusResult Tests', () {
    test('Correctly determines isAllReady flag', () {
      final notReady = PermissionStatusResult(
        permissionsGranted: false,
        bluetoothEnabled: true,
        missingPermissions: ['android.permission.BLUETOOTH_CONNECT'],
      );
      expect(notReady.isAllReady, false);

      final btDisabled = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: false,
        missingPermissions: [],
      );
      expect(btDisabled.isAllReady, false);

      final locDisabled = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: true,
        locationEnabled: false,
        missingPermissions: [],
      );
      // Location is not required for gamepad startup (only requested on-demand when scanning)
      expect(locDisabled.isAllReady, true);

      final allReady = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: true,
        locationEnabled: true,
        missingPermissions: [],
      );
      expect(allReady.isAllReady, true);
    });
  });

  group('Joystick Controller and Layout Tests', () {
    test('Analog joystick calculations for X, Y and Hat switch', () {
      final controller = NesGamepadController();

      // Right
      controller.setJoystick(1.0, 0.0);
      var report = controller.buildReport();
      expect(report[0], 255); // X right
      expect(report[1], 128); // Y neutral
      expect(report[2], 3);   // Hat right

      // Up
      controller.setJoystick(0.0, -1.0);
      report = controller.buildReport();
      expect(report[0], 128); // X neutral
      expect(report[1], 0);   // Y up
      expect(report[2], 1);   // Hat up

      // Left
      controller.setJoystick(-1.0, 0.0);
      report = controller.buildReport();
      expect(report[0], 0);   // X left
      expect(report[1], 128); // Y neutral
      expect(report[2], 7);   // Hat left

      // Down
      controller.setJoystick(0.0, 1.0);
      report = controller.buildReport();
      expect(report[0], 128); // X neutral
      expect(report[1], 255); // Y down
      expect(report[2], 5);   // Hat down

      // Diagonal Down-Right
      controller.setJoystick(0.707, 0.707);
      report = controller.buildReport();
      expect(report[2], 4);   // Hat down-right

      // Deadzone (< 0.25)
      controller.setJoystick(0.1, 0.1);
      report = controller.buildReport();
      expect(report[2], 0);   // Hat centered

      // Reset joystick
      controller.resetJoystick();
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[1], 128);
      expect(report[2], 0);
    });

    test('ControllerLayout preserves directionType across JSON serialization', () {
      final layout = ControllerLayout.defaultLandscape().copyWith(
        directionType: DirectionControlType.joystick,
      );
      expect(layout.directionType, DirectionControlType.joystick);

      final json = layout.toJson();
      final restored = ControllerLayout.fromJson(json);
      expect(restored.directionType, DirectionControlType.joystick);
    });
  });

  group('Haptic Settings & Ergonomic Touch Tests', () {
    test('HapticSettings defaults have vibrateOnAck disabled to prevent constant buzzing', () {
      const settings = HapticSettings();
      expect(settings.enabled, true);
      expect(settings.vibrateOnPress, true);
      expect(settings.vibrateOnDirectionChange, true);
      expect(settings.vibrateOnAck, false); // Crucial fix for constant buzzing!
      expect(settings.aPlusBBridge, true);
      expect(settings.continuousDpad, true);
      expect(settings.swapAB, true); // NES / N64 fix active by default
      expect(settings.swapXY, false);
      expect(settings.strength, HapticStrength.subtle);
    });

    test('HapticSettings JSON serialization round-trip', () {
      const original = HapticSettings(
        enabled: false,
        strength: HapticStrength.strong,
        vibrateOnPress: false,
        vibrateOnDirectionChange: true,
        vibrateOnAck: true,
        aPlusBBridge: false,
        continuousDpad: false,
        swapAB: false,
        swapXY: true,
      );

      final jsonStr = original.toJson();
      final restored = HapticSettings.fromJson(jsonStr);

      expect(restored.enabled, false);
      expect(restored.strength, HapticStrength.strong);
      expect(restored.vibrateOnPress, false);
      expect(restored.vibrateOnDirectionChange, true);
      expect(restored.vibrateOnAck, true);
      expect(restored.aPlusBBridge, false);
      expect(restored.continuousDpad, false);
      expect(restored.swapAB, false);
      expect(restored.swapXY, true);
    });

    test('Simultaneous A and B button press sets both bits in report', () {
      final controller = NesGamepadController();

      controller.pressButton(NesButton.a);
      controller.pressButton(NesButton.b);
      final report = controller.buildReport();

      // Bit 0 = A, Bit 1 = B
      expect(report[3] & (1 << 0), isNot(0), reason: 'Button A must be pressed');
      expect(report[3] & (1 << 1), isNot(0), reason: 'Button B must be pressed');
    });

    test('D-Pad diagonals activate both directions simultaneously', () {
      final controller = NesGamepadController();

      // Up + Right diagonal
      controller.setDpad(up: true, down: false, left: false, right: true);
      final report = controller.buildReport();

      expect(report[0], 255); // X right
      expect(report[1], 0);   // Y up
      expect(report[2], 2);   // Hat switch: Up-Right (2)
    });
  });

  group('RomServer Tests', () {
    test('Starts, serves web manager, handles uploads, downloads, and stops', () async {
      final server = RomServer.instance;

      // Start on a dedicated test port
      final started = await server.start(initialPort: 9876);
      expect(started, true);
      expect(server.isRunning, true);
      expect(server.port, 9876);

      final client = HttpClient();

      try {
        // 1. Test GET / (Web Manager HTML)
        final rootReq = await client.getUrl(Uri.parse('http://127.0.0.1:9876/'));
        final rootResp = await rootReq.close();
        expect(rootResp.statusCode, HttpStatus.ok);
        final rootHtml = await utf8.decodeStream(rootResp);
        expect(rootHtml.contains('ROMs File Manager'), true);

        // 2. Test POST /api/upload?filename=test_mario.nes
        final uploadReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:9876/api/upload?filename=test_mario.nes'),
        );
        uploadReq.headers.contentType = ContentType.binary;
        final sampleRomBytes = utf8.encode('NES_HEADER_TEST_ROM_CONTENT');
        uploadReq.add(sampleRomBytes);
        final uploadResp = await uploadReq.close();
        expect(uploadResp.statusCode, HttpStatus.ok);
        final uploadJson = jsonDecode(await utf8.decodeStream(uploadResp)) as Map<String, dynamic>;
        expect(uploadJson['success'], true);
        expect(uploadJson['filename'], 'test_mario.nes');
        expect(uploadJson['size'], sampleRomBytes.length);

        // 3. Test GET /api/files
        final listReq = await client.getUrl(Uri.parse('http://127.0.0.1:9876/api/files'));
        final listResp = await listReq.close();
        expect(listResp.statusCode, HttpStatus.ok);
        final listJson = jsonDecode(await utf8.decodeStream(listResp)) as Map<String, dynamic>;
        final files = listJson['files'] as List;
        expect(files.any((f) => f['name'] == 'test_mario.nes'), true);

        // 4. Test GET /api/download?file=test_mario.nes
        final dlReq = await client.getUrl(
          Uri.parse('http://127.0.0.1:9876/api/download?file=test_mario.nes'),
        );
        final dlResp = await dlReq.close();
        expect(dlResp.statusCode, HttpStatus.ok);
        final downloadedBytes = await dlResp.fold<List<int>>([], (prev, elem) => prev..addAll(elem));
        expect(utf8.decode(downloadedBytes), 'NES_HEADER_TEST_ROM_CONTENT');

        // 5. Test DELETE /api/delete?file=test_mario.nes
        final delReq = await client.deleteUrl(
          Uri.parse('http://127.0.0.1:9876/api/delete?file=test_mario.nes'),
        );
        final delResp = await delReq.close();
        expect(delResp.statusCode, HttpStatus.ok);

        // Verify file is gone
        final afterListReq = await client.getUrl(Uri.parse('http://127.0.0.1:9876/api/files'));
        final afterListResp = await afterListReq.close();
        final afterListJson = jsonDecode(await utf8.decodeStream(afterListResp)) as Map<String, dynamic>;
        final afterFiles = afterListJson['files'] as List;
        expect(afterFiles.any((f) => f['name'] == 'test_mario.nes'), false);
      } finally {
        client.close();
        await server.stop();
      }

      expect(server.isRunning, false);
    });
  });

  group('TvPusherService & ROM Classification Tests', () {
    test('FormatSize formats bytes into readable units correctly', () {
      expect(TvPusherService.formatSize(500), '500 B');
      expect(TvPusherService.formatSize(1024), '1.0 KB');
      expect(TvPusherService.formatSize(40960), '40.0 KB');
      expect(TvPusherService.formatSize(1048576), '1.0 MB');
      expect(TvPusherService.formatSize(1073741824), '1.00 GB');
    });

    test('getPlatformBadge identifies retro console platforms correctly', () {
      expect(TvPusherService.getPlatformBadge('SuperMario.nes'), 'NES');
      expect(TvPusherService.getPlatformBadge('Zelda.FDS'), 'NES');
      expect(TvPusherService.getPlatformBadge('ChronoTrigger.sfc'), 'SNES');
      expect(TvPusherService.getPlatformBadge('SuperMarioWorld.smc'), 'SNES');
      expect(TvPusherService.getPlatformBadge('PokemonEmerald.gba'), 'GBA');
      expect(TvPusherService.getPlatformBadge('Tetris.gb'), 'GAME BOY');
      expect(TvPusherService.getPlatformBadge('PokemonGold.gbc'), 'GAME BOY');
      expect(TvPusherService.getPlatformBadge('Mario64.z64'), 'N64');
      expect(TvPusherService.getPlatformBadge('Sonic2.gen'), 'GENESIS');
      expect(TvPusherService.getPlatformBadge('Sonic3.md'), 'GENESIS');
      expect(TvPusherService.getPlatformBadge('Tekken.iso'), 'PSP/PSX');
      expect(TvPusherService.getPlatformBadge('Crash.bin'), 'PS1/ARCADE');
      expect(TvPusherService.getPlatformBadge('MarioKartDS.nds'), 'NDS');
      expect(TvPusherService.getPlatformBadge('RomsPack.zip'), 'ARCHIVE');
      expect(TvPusherService.getPlatformBadge('unknown_game.xyz'), 'ROM');
    });

    test('RomFileInfo serializes and computes getters properly', () {
      final fileInfo = RomFileInfo.fromMap({
        'path': '/storage/emulated/0/roms/Contra.nes',
        'name': 'Contra.nes',
        'size': 131072,
      });

      expect(fileInfo.path, '/storage/emulated/0/roms/Contra.nes');
      expect(fileInfo.name, 'Contra.nes');
      expect(fileInfo.size, 131072);
      expect(fileInfo.formattedSize, '128.0 KB');
      expect(fileInfo.platformBadge, 'NES');
    });
  });

  group('N64 Gamepad Controller Tests', () {
    test('Initial state is neutral across all dual-dial axes and buttons', () {
      final controller = N64GamepadController();
      final report = controller.buildReport();

      // Report format: [lx, ly, rx, ry, hat, buttonsLow, buttonsHigh]
      expect(report.length, 7);
      expect(report[0], 128); // Left Stick X neutral
      expect(report[1], 128); // Left Stick Y neutral
      expect(report[2], 128); // Right C-Stick Z neutral
      expect(report[3], 128); // Right C-Stick Rz neutral
      expect(report[4], 0);   // Hat switch centered
      expect(report[5], 0);   // Buttons 1-8 released
      expect(report[6], 0);   // Buttons 9-16 released
    });

    test('Left analog movement stick calculates full range X and Y', () {
      final controller = N64GamepadController();

      // Stick fully Right
      controller.setStick(1.0, 0.0);
      var report = controller.buildReport();
      expect(report[0], 255);
      expect(report[1], 128);

      // Stick fully Up
      controller.setStick(0.0, -1.0);
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[1], 0);

      // Reset stick
      controller.resetStick();
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[1], 128);
    });

    test('Right C-Stick dialer calculates Z and Rz axes with virtual C-buttons', () {
      final controller = N64GamepadController();

      // C-Stick tilted Right
      controller.setCStick(1.0, 0.0);
      var report = controller.buildReport();
      expect(report[2], 255); // rx / Z axis right
      expect(report[3], 128); // ry / Rz axis neutral
      expect(report[6] & (1 << 1), isNot(0), reason: 'C-Right button bit should also be set');

      // C-Stick tilted Up
      controller.setCStick(0.0, -1.0);
      report = controller.buildReport();
      expect(report[2], 128);
      expect(report[3], 0);   // ry / Rz axis up
      expect(report[5] & (1 << 3), isNot(0), reason: 'C-Up button bit should also be set');

      controller.resetCStick();
      report = controller.buildReport();
      expect(report[2], 128);
      expect(report[3], 128);
      expect(report[5], 0);
      expect(report[6], 0);
    });

    test('Direct C-Buttons update both bitmasks and virtual C-Stick analog axes', () {
      final controller = N64GamepadController();

      // Press C-Down and C-Left
      controller.setCButtons(up: false, down: true, left: true, right: false);
      final report = controller.buildReport();

      // Check analog representation
      expect(report[2], 0);   // rx = Left (0)
      expect(report[3], 255); // ry = Down (255)

      // Check button bitmasks: C-Down (bit 4 of low), C-Left (bit 5 of low)
      expect(report[5] & (1 << 4), isNot(0));
      expect(report[5] & (1 << 5), isNot(0));
    });

    test('Action buttons A (Blue), B (Green), Z-Trigger, L, R and Start', () {
      final controller = N64GamepadController();

      // Button A (Jump: bit 1 of buttonsLow)
      controller.pressButton(N64Button.a);
      var report = controller.buildReport();
      expect(report[5] & (1 << 1), isNot(0), reason: 'A button is bit 1');

      // Button B (Attack: bit 0 of buttonsLow)
      controller.pressButton(N64Button.b);
      report = controller.buildReport();
      expect(report[5] & (1 << 0), isNot(0), reason: 'B button is bit 0');

      // Z-Trigger (bit 2 of buttonsLow and bit 0 of buttonsHigh)
      controller.pressButton(N64Button.zTrigger);
      report = controller.buildReport();
      expect(report[5] & (1 << 2), isNot(0), reason: 'Z Trigger in low byte');
      expect(report[6] & (1 << 0), isNot(0), reason: 'Z Trigger in high byte');

      // L & R Bumpers (bits 6 and 7 of buttonsLow)
      controller.pressButton(N64Button.lBumper);
      controller.pressButton(N64Button.rBumper);
      report = controller.buildReport();
      expect(report[5] & (1 << 6), isNot(0), reason: 'L Bumper');
      expect(report[5] & (1 << 7), isNot(0), reason: 'R Bumper');

      // Start Button (bit 3 of buttonsHigh)
      controller.pressButton(N64Button.start);
      report = controller.buildReport();
      expect(report[6] & (1 << 3), isNot(0), reason: 'Start button');

      // Reset
      controller.reset();
      report = controller.buildReport();
      expect(report[5], 0);
      expect(report[6], 0);
    });

    test('N64 D-Pad calculates 8-way Hat Switch and mirrors to left stick when stick idle', () {
      final controller = N64GamepadController();

      controller.setDpad(up: true, down: false, left: false, right: true);
      final report = controller.buildReport();

      expect(report[4], 2); // Hat switch Up-Right (2)
      expect(report[0], 255); // Mirrored to stick X
      expect(report[1], 0);   // Mirrored to stick Y
    });
  });

  group('ControllerFactory Tests', () {
    test('Available types contains nes and n64', () {
      final types = ControllerFactory.availableTypes;
      expect(types, contains(ControllerType.nes));
      expect(types, contains(ControllerType.n64));
    });

    test('createController instantiates correct controller subclasses', () {
      final nesCtrl = ControllerFactory.createController(ControllerType.nes);
      expect(nesCtrl, isA<NesGamepadController>());
      expect(nesCtrl.name, 'NES Gamepad');

      final n64Ctrl = ControllerFactory.createController(ControllerType.n64);
      expect(n64Ctrl, isA<N64GamepadController>());
      expect(n64Ctrl.name, 'N64 Gamepad');
    });

    test('getDisplayName and getShortName produce friendly names', () {
      expect(ControllerFactory.getDisplayName(ControllerType.nes), contains('NES'));
      expect(ControllerFactory.getDisplayName(ControllerType.nes), contains('1 Dial Pad'));
      expect(ControllerFactory.getDisplayName(ControllerType.n64), contains('N64'));
      expect(ControllerFactory.getDisplayName(ControllerType.n64), contains('Dual Dialers'));

      expect(ControllerFactory.getShortName(ControllerType.nes), 'NES');
      expect(ControllerFactory.getShortName(ControllerType.n64), 'N64');
    });
  });
}
