import 'package:permission_handler/permission_handler.dart';

import 'native_bridge.dart';

class PermissionResult {
  final bool ok;
  final bool permanentlyDenied;
  final bool locationServiceOff;
  const PermissionResult(this.ok,
      {this.permanentlyDenied = false, this.locationServiceOff = false});
}

/// Asks for exactly what Nearby Connections needs on this Android version.
///
///  * Android 12+ (31): BLUETOOTH_SCAN / ADVERTISE / CONNECT
///  * Android 13+ (33): NEARBY_WIFI_DEVICES, POST_NOTIFICATIONS
///  * Android ≤ 12L (32): fine location, and Location must be switched on
Future<PermissionResult> requestMeshPermissions() async {
  var sdk = await NativeBridge.sdkInt();
  // Unknown SDK (native side missing): ask for everything. permission_handler
  // reports permissions that don't exist on this Android version as granted.
  final unknown = sdk == 0;
  if (unknown) sdk = 33;
  final needed = <Permission>[];
  if (unknown) needed.add(Permission.location);
  if (sdk >= 31) {
    needed.addAll([
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ]);
  }
  if (sdk >= 33) needed.add(Permission.nearbyWifiDevices);
  if (sdk <= 32) needed.add(Permission.location);

  final statuses = await needed.request();

  // Notifications are nice-to-have, never block the mesh on them.
  if (sdk >= 33) await Permission.notification.request();

  final denied = statuses.entries
  // In the unknown-SDK fallback, location is a guess: don't block on it.
      .where((e) => !e.value.isGranted && !(unknown && e.key == Permission.location))
      .toList();
  if (denied.isNotEmpty) {
    return PermissionResult(false,
        permanentlyDenied: denied.any((e) => e.value.isPermanentlyDenied));
  }

  if (sdk <= 32) {
    final service = await Permission.location.serviceStatus;
    if (!service.isEnabled) {
      return const PermissionResult(false, locationServiceOff: true);
    }
  }
  return const PermissionResult(true);
}

/// Microphone, for voice messages and calls. Asked the first time it's needed.
Future<bool> requestMicrophone() async =>
    (await Permission.microphone.request()).isGranted;