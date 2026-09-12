import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Configuration for an individual button cluster (e.g. D-Pad, A/B buttons, Select/Start).
class ClusterLayout {
  /// Normalized X coordinate (0.0 to 1.0) representing center or anchor position.
  final double dx;

  /// Normalized Y coordinate (0.0 to 1.0) representing center or anchor position.
  final double dy;

  /// Scale multiplier (e.g., 0.5x to 2.5x, default 1.0).
  final double scale;

  /// Rotation angle in radians (default 0.0).
  final double rotation;

  const ClusterLayout({
    required this.dx,
    required this.dy,
    this.scale = 1.0,
    this.rotation = 0.0,
  });

  ClusterLayout copyWith({
    double? dx,
    double? dy,
    double? scale,
    double? rotation,
  }) {
    return ClusterLayout(
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'dx': dx,
      'dy': dy,
      'scale': scale,
      'rotation': rotation,
    };
  }

  factory ClusterLayout.fromMap(Map<String, dynamic> map) {
    return ClusterLayout(
      dx: (map['dx'] as num?)?.toDouble() ?? 0.5,
      dy: (map['dy'] as num?)?.toDouble() ?? 0.5,
      scale: (map['scale'] as num?)?.toDouble() ?? 1.0,
      rotation: (map['rotation'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

enum DirectionControlType {
  dpad,
  joystick,
}

/// Complete controller layout holding positions and scales for all clusters.
class ControllerLayout {
  final ClusterLayout dpad;
  final ClusterLayout actionButtons;
  final ClusterLayout menuButtons;
  final DirectionControlType directionType;

  const ControllerLayout({
    required this.dpad,
    required this.actionButtons,
    required this.menuButtons,
    this.directionType = DirectionControlType.dpad,
  });

  /// Default layout optimized for Landscape orientation (handheld two-thumb layout).
  factory ControllerLayout.defaultLandscape() {
    return const ControllerLayout(
      // Left side thumb zone
      dpad: ClusterLayout(dx: 0.18, dy: 0.60, scale: 1.15),
      // Right side thumb zone
      actionButtons: ClusterLayout(dx: 0.82, dy: 0.60, scale: 1.15),
      // Bottom center
      menuButtons: ClusterLayout(dx: 0.50, dy: 0.82, scale: 0.95),
      directionType: DirectionControlType.dpad,
    );
  }

  /// Default layout optimized for Portrait orientation.
  factory ControllerLayout.defaultPortrait() {
    return const ControllerLayout(
      // Lower-left
      dpad: ClusterLayout(dx: 0.26, dy: 0.65, scale: 1.0),
      // Lower-right
      actionButtons: ClusterLayout(dx: 0.74, dy: 0.65, scale: 1.0),
      // Center
      menuButtons: ClusterLayout(dx: 0.50, dy: 0.44, scale: 0.9),
      directionType: DirectionControlType.dpad,
    );
  }

  ControllerLayout copyWith({
    ClusterLayout? dpad,
    ClusterLayout? actionButtons,
    ClusterLayout? menuButtons,
    DirectionControlType? directionType,
  }) {
    return ControllerLayout(
      dpad: dpad ?? this.dpad,
      actionButtons: actionButtons ?? this.actionButtons,
      menuButtons: menuButtons ?? this.menuButtons,
      directionType: directionType ?? this.directionType,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'dpad': dpad.toMap(),
      'actionButtons': actionButtons.toMap(),
      'menuButtons': menuButtons.toMap(),
      'directionType': directionType.name,
    };
  }

  factory ControllerLayout.fromMap(Map<String, dynamic> map) {
    return ControllerLayout(
      dpad: map['dpad'] != null
          ? ClusterLayout.fromMap(Map<String, dynamic>.from(map['dpad'] as Map))
          : const ClusterLayout(dx: 0.2, dy: 0.6),
      actionButtons: map['actionButtons'] != null
          ? ClusterLayout.fromMap(Map<String, dynamic>.from(map['actionButtons'] as Map))
          : const ClusterLayout(dx: 0.8, dy: 0.6),
      menuButtons: map['menuButtons'] != null
          ? ClusterLayout.fromMap(Map<String, dynamic>.from(map['menuButtons'] as Map))
          : const ClusterLayout(dx: 0.5, dy: 0.8),
      directionType: map['directionType'] == 'joystick'
          ? DirectionControlType.joystick
          : DirectionControlType.dpad,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory ControllerLayout.fromJson(String source) {
    return ControllerLayout.fromMap(jsonDecode(source) as Map<String, dynamic>);
  }

  // ==========================================
  // PERSISTENCE HELPER (Native SharedPreferences)
  // ==========================================
  static const MethodChannel _channel = MethodChannel('com.example.ble/gamepad');

  static Future<void> save(Orientation orientation, ControllerLayout layout) async {
    final key = orientation == Orientation.landscape
        ? 'layout_landscape'
        : 'layout_portrait';
    try {
      await _channel.invokeMethod('savePreference', {
        'key': key,
        'value': layout.toJson(),
      });
    } catch (_) {
      // Ignored if channel not available
    }
  }

  static Future<ControllerLayout> load(Orientation orientation) async {
    final key = orientation == Orientation.landscape
        ? 'layout_landscape'
        : 'layout_portrait';
    try {
      final jsonStr = await _channel.invokeMethod<String>('getPreference', {'key': key});
      if (jsonStr != null && jsonStr.isNotEmpty) {
        return ControllerLayout.fromJson(jsonStr);
      }
    } catch (_) {
      // Ignored
    }
    return orientation == Orientation.landscape
        ? ControllerLayout.defaultLandscape()
        : ControllerLayout.defaultPortrait();
  }
}
