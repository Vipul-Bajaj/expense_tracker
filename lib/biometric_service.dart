import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class BiometricAuthService {
  static final LocalAuthentication _auth = LocalAuthentication();

  /// Checks if the device supports biometric authentication or device credentials
  static Future<bool> canCheckBiometrics() async {
    try {
      final bool isSupported = await _auth.isDeviceSupported();
      final bool canCheck = await _auth.canCheckBiometrics;
      return isSupported || canCheck;
    } on PlatformException catch (e) {
      debugPrint("BiometricAuthService canCheckBiometrics error: $e");
      return false;
    } catch (e) {
      debugPrint("BiometricAuthService canCheckBiometrics unexpected error: $e");
      return false;
    }
  }

  /// Returns a list of available biometric types (Face, Fingerprint, Iris)
  static Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException catch (e) {
      debugPrint("BiometricAuthService getAvailableBiometrics error: $e");
      return <BiometricType>[];
    } catch (e) {
      debugPrint("BiometricAuthService getAvailableBiometrics unexpected error: $e");
      return <BiometricType>[];
    }
  }

  /// Prompts the user to authenticate with biometrics or device PIN/pattern
  static Future<bool> authenticate({
    String localizedReason = 'Please authenticate to access your finances',
  }) async {
    try {
      final bool canAuthenticate = await canCheckBiometrics();
      if (!canAuthenticate) {
        debugPrint("BiometricAuthService: Device does not support biometric or device authentication.");
        return false;
      }

      return await _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
          sensitiveTransaction: true,
        ),
      );
    } on PlatformException catch (e) {
      debugPrint("BiometricAuthService authenticate error: $e");
      return false;
    } catch (e) {
      debugPrint("BiometricAuthService authenticate unexpected error: $e");
      return false;
    }
  }
}
