import 'dart:convert';
import 'package:flutter/services.dart';

enum HapticStrength {
  subtle,
  medium,
  strong,
}

enum HapticTriggerType {
  buttonPress,
  directionChange,
  ack,
}

class HapticSettings {
  final bool enabled;
  final HapticStrength strength;
  final bool vibrateOnPress;
  final bool vibrateOnDirectionChange;
  final bool vibrateOnAck;
  final bool aPlusBBridge;
  final bool continuousDpad;
  final bool swapAB;
  final bool swapXY;

  const HapticSettings({
    this.enabled = true,
    this.strength = HapticStrength.subtle,
    this.vibrateOnPress = true,
    this.vibrateOnDirectionChange = true,
    this.vibrateOnAck = false, // Off by default to avoid constant vibration
    this.aPlusBBridge = true, // Allows single thumb to bridge A & B together
    this.continuousDpad = true, // Smooth rolling 8-way D-Pad
    this.swapAB = true, // NES & N64 mode: A = Jump, B = Run/Attack correctly mapped
    this.swapXY = false,
  });

  HapticSettings copyWith({
    bool? enabled,
    HapticStrength? strength,
    bool? vibrateOnPress,
    bool? vibrateOnDirectionChange,
    bool? vibrateOnAck,
    bool? aPlusBBridge,
    bool? continuousDpad,
    bool? swapAB,
    bool? swapXY,
  }) {
    return HapticSettings(
      enabled: enabled ?? this.enabled,
      strength: strength ?? this.strength,
      vibrateOnPress: vibrateOnPress ?? this.vibrateOnPress,
      vibrateOnDirectionChange: vibrateOnDirectionChange ?? this.vibrateOnDirectionChange,
      vibrateOnAck: vibrateOnAck ?? this.vibrateOnAck,
      aPlusBBridge: aPlusBBridge ?? this.aPlusBBridge,
      continuousDpad: continuousDpad ?? this.continuousDpad,
      swapAB: swapAB ?? this.swapAB,
      swapXY: swapXY ?? this.swapXY,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'strength': strength.name,
      'vibrateOnPress': vibrateOnPress,
      'vibrateOnDirectionChange': vibrateOnDirectionChange,
      'vibrateOnAck': vibrateOnAck,
      'aPlusBBridge': aPlusBBridge,
      'continuousDpad': continuousDpad,
      'swapAB': swapAB,
      'swapXY': swapXY,
    };
  }

  factory HapticSettings.fromMap(Map<String, dynamic> map) {
    HapticStrength parsedStrength = HapticStrength.subtle;
    final strVal = map['strength'] as String?;
    if (strVal != null) {
      for (final s in HapticStrength.values) {
        if (s.name == strVal) {
          parsedStrength = s;
          break;
        }
      }
    }

    return HapticSettings(
      enabled: (map['enabled'] as bool?) ?? true,
      strength: parsedStrength,
      vibrateOnPress: (map['vibrateOnPress'] as bool?) ?? true,
      vibrateOnDirectionChange: (map['vibrateOnDirectionChange'] as bool?) ?? true,
      vibrateOnAck: (map['vibrateOnAck'] as bool?) ?? false,
      aPlusBBridge: (map['aPlusBBridge'] as bool?) ?? true,
      continuousDpad: (map['continuousDpad'] as bool?) ?? true,
      swapAB: (map['swapAB'] as bool?) ?? true,
      swapXY: (map['swapXY'] as bool?) ?? false,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory HapticSettings.fromJson(String source) {
    return HapticSettings.fromMap(jsonDecode(source) as Map<String, dynamic>);
  }

  /// Triggers the appropriate haptic feedback based on active settings.
  void trigger(HapticTriggerType type) {
    if (!enabled) return;

    switch (type) {
      case HapticTriggerType.buttonPress:
        if (!vibrateOnPress) return;
        executeFeedback();
        break;
      case HapticTriggerType.directionChange:
        if (!vibrateOnDirectionChange) return;
        // Direction change is always crisp and subtle so it doesn't fatigue fingers
        HapticFeedback.selectionClick();
        break;
      case HapticTriggerType.ack:
        if (!vibrateOnAck) return;
        HapticFeedback.selectionClick();
        break;
    }
  }

  void executeFeedback() {
    switch (strength) {
      case HapticStrength.subtle:
        HapticFeedback.selectionClick();
        break;
      case HapticStrength.medium:
        HapticFeedback.lightImpact();
        break;
      case HapticStrength.strong:
        HapticFeedback.mediumImpact();
        break;
    }
  }

  // ==========================================
  // PERSISTENCE (Native SharedPreferences)
  // ==========================================
  static const MethodChannel _channel = MethodChannel('com.example.ble/gamepad');
  static const String _prefKey = 'haptic_settings';

  static Future<void> save(HapticSettings settings) async {
    try {
      await _channel.invokeMethod('savePreference', {
        'key': _prefKey,
        'value': settings.toJson(),
      });
    } catch (_) {}
  }

  static Future<HapticSettings> load() async {
    try {
      final jsonStr = await _channel.invokeMethod<String>('getPreference', {'key': _prefKey});
      if (jsonStr != null && jsonStr.isNotEmpty) {
        return HapticSettings.fromJson(jsonStr);
      }
    } catch (_) {}
    return const HapticSettings();
  }
}
