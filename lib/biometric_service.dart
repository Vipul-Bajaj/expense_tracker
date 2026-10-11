import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

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

  /// Cancels any in-progress authentication
  static Future<bool> stopAuthentication() async {
    try {
      return await _auth.stopAuthentication();
    } catch (e) {
      debugPrint("BiometricAuthService stopAuthentication error: $e");
      return false;
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

      // Reset any stuck authentication before launching
      try {
        await _auth.stopAuthentication();
      } catch (_) {}

      final bool result = await _auth.authenticate(
        localizedReason: localizedReason,
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Unlock Expense Tracker',
            cancelButton: 'Cancel',
            signInHint: 'Verify your fingerprint, face, or PIN',
          ),
        ],
        biometricOnly: false,
        sensitiveTransaction: false,
        persistAcrossBackgrounding: false,
      );
      debugPrint("BiometricAuthService authenticate result: $result");
      return result;
    } on PlatformException catch (e) {
      debugPrint("BiometricAuthService authenticate PlatformException: ${e.code} - ${e.message}");
      return false;
    } catch (e) {
      debugPrint("BiometricAuthService authenticate unexpected error: $e");
      return false;
    }
  }
}
