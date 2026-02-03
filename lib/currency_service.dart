import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive/hive.dart';
import 'package:flutter/foundation.dart';

class CurrencyService {
  static const String _baseUrl = 'https://api.frankfurter.app/latest';
  static const String _baseCurrency = 'INR';

  static Future<bool> updateRates() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl?from=$_baseCurrency&to=USD,EUR'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final Map<String, dynamic> rates = data['rates'];
        
        final box = Hive.box('settings');
        await box.put('rate_usd', (rates['USD'] as num).toDouble());
        await box.put('rate_eur', (rates['EUR'] as num).toDouble());
        await box.put('rates_last_updated', DateTime.now().millisecondsSinceEpoch);
        
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error updating rates: $e');
      return false;
    }
  }

  static String getLastUpdatedText() {
    final box = Hive.box('settings');
    final int? timestamp = box.get('rates_last_updated');
    if (timestamp == null) return "Never updated";
    
    final lastUpdated = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(lastUpdated);

    if (difference.inMinutes < 1) return "Just now";
    if (difference.inHours < 1) return "${difference.inMinutes}m ago";
    if (difference.inDays < 1) return "${difference.inHours}h ago";
    return "${difference.inDays}d ago";
  }
}
