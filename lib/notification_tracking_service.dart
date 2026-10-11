import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

enum DetectedTransactionType { expense, income }

class DetectedTransaction {
  final String id;
  final double amount;
  final String payee;
  final String category;
  final String accountName;
  final DetectedTransactionType type;
  final DateTime timestamp;
  final String rawTitle;
  final String rawContent;
  final String packageName;
  String status; // 'pending', 'approved', 'dismissed'

  DetectedTransaction({
    required this.id,
    required this.amount,
    required this.payee,
    required this.category,
    required this.accountName,
    required this.type,
    required this.timestamp,
    required this.rawTitle,
    required this.rawContent,
    required this.packageName,
    this.status = 'pending',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'amount': amount,
      'payee': payee,
      'category': category,
      'accountName': accountName,
      'type': type.index,
      'timestamp': timestamp.toIso8601String(),
      'rawTitle': rawTitle,
      'rawContent': rawContent,
      'packageName': packageName,
      'status': status,
    };
  }

  factory DetectedTransaction.fromMap(Map<dynamic, dynamic> map) {
    return DetectedTransaction(
      id: map['id'] as String? ??
          '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}',
      amount: (map['amount'] as num).toDouble(),
      payee: map['payee'] as String? ?? 'Unknown',
      category: map['category'] as String? ?? 'Food',
      accountName: map['accountName'] as String? ?? 'UPI / Bank',
      type: DetectedTransactionType.values[(map['type'] as int?) ?? 0],
      timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ?? DateTime.now(),
      rawTitle: map['rawTitle'] as String? ?? '',
      rawContent: map['rawContent'] as String? ?? '',
      packageName: map['packageName'] as String? ?? '',
      status: map['status'] as String? ?? 'pending',
    );
  }
}

class NotificationTrackingService {
  static StreamSubscription<ServiceNotificationEvent>? _subscription;
  static final ValueNotifier<List<DetectedTransaction>> pendingTransactionsNotifier =
      ValueNotifier<List<DetectedTransaction>>([]);
  
  static final Set<String> _recentSignatures = {};

  /// Known payment and banking package names
  static final Map<String, String> knownPackages = {
    'com.google.android.apps.nbu.paisa.user': 'Google Pay',
    'com.phonepe.app': 'PhonePe',
    'net.one97.paytm': 'Paytm',
    'com.dreamplug.androidapp': 'CRED',
    'in.org.npci.upiapp': 'BHIM UPI',
    'in.amazon.mShop.android.shopping': 'Amazon Pay',
    'com.snapwork.hdfc': 'HDFC Bank',
    'com.csam.icici.bank.imobile': 'ICICI Bank',
    'com.axis.mobile': 'Axis Bank',
    'com.sbi.lotusintouch': 'SBI YONO',
    'com.msf.kbank.mobile': 'Kotak Bank',
    'com.google.android.apps.messaging': 'SMS',
    'com.samsung.android.messaging': 'SMS',
  };

  /// Initialize the notification listener
  static Future<void> initialize() async {
    // Open detected transactions storage box
    if (!Hive.isBoxOpen('detected_transactions')) {
      await Hive.openBox('detected_transactions');
    }
    _loadPendingTransactions();

    final settingsBox = Hive.box('settings');
    final bool isEnabled = settingsBox.get('autoDetectTransactions', defaultValue: false);

    if (isEnabled) {
      startListening();
    }
  }

  /// Load pending detected transactions from Hive
  static void _loadPendingTransactions() {
    try {
      final box = Hive.box('detected_transactions');
      final List<DetectedTransaction> list = [];
      for (var key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          final item = DetectedTransaction.fromMap(val);
          if (item.status == 'pending') {
            list.add(item);
          }
        }
      }
      // Sort newest first
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      pendingTransactionsNotifier.value = list;
    } catch (e) {
      debugPrint("Error loading pending transactions: $e");
    }
  }

  /// Check if the system Notification Access permission is granted
  static Future<bool> isPermissionGranted() async {
    try {
      return await NotificationListenerService.isPermissionGranted();
    } catch (e) {
      debugPrint("isPermissionGranted error: $e");
      return false;
    }
  }

  /// Request Notification Access in Android Settings
  static Future<bool> requestPermission() async {
    try {
      return await NotificationListenerService.requestPermission();
    } catch (e) {
      debugPrint("requestPermission error: $e");
      return false;
    }
  }

  /// Start streaming incoming notifications
  static void startListening() {
    _subscription?.cancel();
    try {
      _subscription = NotificationListenerService.notificationsStream.listen(
        (event) {
          _handleNotificationEvent(event);
        },
        onError: (err) {
          debugPrint("NotificationListenerService stream error: $err");
        },
      );
      debugPrint("NotificationTrackingService started listening.");
    } catch (e) {
      debugPrint("Failed to start notification listener: $e");
    }
  }

  /// Stop streaming incoming notifications
  static void stopListening() {
    _subscription?.cancel();
    _subscription = null;
    debugPrint("NotificationTrackingService stopped listening.");
  }

  /// Parse and process an incoming notification event
  static void _handleNotificationEvent(ServiceNotificationEvent event) {
    if (event.hasRemoved) return;

    final pkg = event.packageName;
    final title = event.title;
    final content = event.content;

    // If it's not a known payment app or an SMS app, check if it contains banking keywords
    bool isPaymentApp = knownPackages.containsKey(pkg);
    bool hasPaymentKeywords = _hasFinancialKeywords('$title $content');

    if (!isPaymentApp && !hasPaymentKeywords) {
      return;
    }

    final parsed = parseTransactionText(
      title: title,
      content: content,
      packageName: pkg,
    );

    if (parsed != null) {
      _processDetectedTransaction(parsed);
    }
  }

  /// Check if text contains Indian banking/payment keywords
  static bool _hasFinancialKeywords(String text) {
    final lower = text.toLowerCase();
    return lower.contains('paid') ||
        lower.contains('debited') ||
        lower.contains('spent') ||
        lower.contains('credited') ||
        lower.contains('sent rs') ||
        lower.contains('sent inr') ||
        lower.contains('₹') ||
        lower.contains('vpa') ||
        lower.contains('upi');
  }

  /// Extract transaction data from notification title & body text
  static DetectedTransaction? parseTransactionText({
    required String title,
    required String content,
    String packageName = '',
  }) {
    final fullText = '$title $content';
    final lower = fullText.toLowerCase();

    // 1. Amount Extraction
    // Patterns: ₹ 500, Rs. 500, Rs 500, INR 500.00, 500.00 INR
    final amountRegex = RegExp(
      r'(?:₹|rs\.?|inr)\s*([0-9,]+(?:\.[0-9]{1,2})?)',
      caseSensitive: false,
    );
    final match = amountRegex.firstMatch(fullText);

    if (match == null) {
      return null;
    }

    final rawAmountStr = match.group(1)?.replaceAll(',', '');
    if (rawAmountStr == null) return null;
    final double? amount = double.tryParse(rawAmountStr);
    if (amount == null || amount <= 0) return null;

    // 2. Type Extraction (Default: Expense)
    DetectedTransactionType type = DetectedTransactionType.expense;
    if (lower.contains('credited') ||
        lower.contains('received') ||
        lower.contains('refund') ||
        lower.contains('cashback') ||
        lower.contains('added to')) {
      type = DetectedTransactionType.income;
    }

    // 3. Account / App Name
    String accountName = knownPackages[packageName] ?? 'Bank / Card';
    if (lower.contains('hdfc')) accountName = 'HDFC Bank';
    if (lower.contains('icici')) accountName = 'ICICI Bank';
    if (lower.contains('sbi')) accountName = 'SBI';
    if (lower.contains('axis')) accountName = 'Axis Bank';
    if (lower.contains('kotak')) accountName = 'Kotak Bank';
    if (lower.contains('gpay') || lower.contains('google pay')) accountName = 'Google Pay';
    if (lower.contains('phonepe')) accountName = 'PhonePe';
    if (lower.contains('paytm')) accountName = 'Paytm';
    if (lower.contains('cred')) accountName = 'CRED';

    // 4. Payee / Merchant Extraction
    String payee = _extractPayee(title, content, lower);

    // 5. Inferred Category
    String category = inferCategory(payee, lower);

    return DetectedTransaction(
      id: '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}',
      amount: amount,
      payee: payee,
      category: category,
      accountName: accountName,
      type: type,
      timestamp: DateTime.now(),
      rawTitle: title,
      rawContent: content,
      packageName: packageName,
      status: 'pending',
    );
  }

  /// Extract merchant / recipient from notification text
  static String _extractPayee(String title, String content, String lower) {
    // Look for "paid to [Payee]" or "to [Payee]" or "at [Payee]"
    final toPattern = RegExp(
      r'(?:paid to|sent to|to|at|for|vpa)\s+([A-Za-z0-9\s&.-]{2,30}?)(?:\s+(?:on|via|using|from|ref|upi|avl|avbl|bal|a\/c|ending)|\.|\,|$)',
      caseSensitive: false,
    );
    final match = toPattern.firstMatch('$content $title');
    if (match != null) {
      String candidate = match.group(1)?.trim() ?? '';
      // Exclude generic noise
      if (candidate.isNotEmpty &&
          !candidate.toLowerCase().contains('account') &&
          !candidate.toLowerCase().contains('card') &&
          !candidate.toLowerCase().contains('bank') &&
          candidate.length > 1) {
        return _capitalize(candidate);
      }
    }

    // Fallback: If title has the merchant name (e.g. Swiggy, Zomato, Uber)
    if (title.isNotEmpty &&
        title.length < 25 &&
        !title.toLowerCase().contains('bank') &&
        !title.toLowerCase().contains('alert')) {
      return title.trim();
    }

    return 'Merchant / UPI';
  }

  /// Infer appropriate category based on merchant or keywords
  static String inferCategory(String payee, String fullText) {
    final lower = '$payee $fullText'.toLowerCase();

    if (lower.contains('swiggy') ||
        lower.contains('zomato') ||
        lower.contains('mcdonald') ||
        lower.contains('burger') ||
        lower.contains('pizza') ||
        lower.contains('chai') ||
        lower.contains('tea') ||
        lower.contains('coffee') ||
        lower.contains('starbucks') ||
        lower.contains('bakery') ||
        lower.contains('restaurant') ||
        lower.contains('dhaba') ||
        lower.contains('cafe') ||
        lower.contains('food')) {
      return 'Food';
    }

    if (lower.contains('blinkit') ||
        lower.contains('zepto') ||
        lower.contains('instamart') ||
        lower.contains('bigbasket') ||
        lower.contains('dmart') ||
        lower.contains('supermarket') ||
        lower.contains('grocery') ||
        lower.contains('fresh')) {
      return 'Food'; // Or Subcategory Groceries
    }

    if (lower.contains('uber') ||
        lower.contains('ola') ||
        lower.contains('rapido') ||
        lower.contains('metro') ||
        lower.contains('fuel') ||
        lower.contains('petrol') ||
        lower.contains('diesel') ||
        lower.contains('indianoil') ||
        lower.contains('bharat petroleum') ||
        lower.contains('hpcl') ||
        lower.contains('shell') ||
        lower.contains('fastag') ||
        lower.contains('toll')) {
      return 'Transport';
    }

    if (lower.contains('amazon') ||
        lower.contains('flipkart') ||
        lower.contains('myntra') ||
        lower.contains('ajio') ||
        lower.contains('zara') ||
        lower.contains('h&m') ||
        lower.contains('meesho') ||
        lower.contains('nykaa') ||
        lower.contains('croma') ||
        lower.contains('shopping') ||
        lower.contains('retail')) {
      return 'Shopping';
    }

    if (lower.contains('electricity') ||
        lower.contains('bescom') ||
        lower.contains('tata power') ||
        lower.contains('airtel') ||
        lower.contains('jio') ||
        lower.contains('vi') ||
        lower.contains('broadband') ||
        lower.contains('wifi') ||
        lower.contains('water') ||
        lower.contains('gas') ||
        lower.contains('bill')) {
      return 'Bills';
    }

    if (lower.contains('netflix') ||
        lower.contains('spotify') ||
        lower.contains('prime') ||
        lower.contains('hotstar') ||
        lower.contains('pvr') ||
        lower.contains('inox') ||
        lower.contains('bookmyshow') ||
        lower.contains('movie') ||
        lower.contains('cinema')) {
      return 'Entmt';
    }

    if (lower.contains('apollo') ||
        lower.contains('pharmacy') ||
        lower.contains('1mg') ||
        lower.contains('netmeds') ||
        lower.contains('pharmeasy') ||
        lower.contains('hospital') ||
        lower.contains('clinic') ||
        lower.contains('doctor') ||
        lower.contains('medplus') ||
        lower.contains('health')) {
      return 'Health';
    }

    if (lower.contains('zerodha') ||
        lower.contains('groww') ||
        lower.contains('coin') ||
        lower.contains('kuvera') ||
        lower.contains('sip') ||
        lower.contains('mutual fund') ||
        lower.contains('invest')) {
      return 'Investment';
    }

    return 'Other';
  }

  /// Process the detected transaction (deduplicate and save)
  static Future<void> _processDetectedTransaction(DetectedTransaction txn) async {
    // Deduplication signature: amount + payee within a 5-minute window
    final signature = '${txn.amount}_${txn.payee.toLowerCase()}_${DateTime.now().minute ~/ 5}';
    if (_recentSignatures.contains(signature)) {
      debugPrint("Duplicate notification transaction ignored: $signature");
      return;
    }
    _recentSignatures.add(signature);

    // Save to Hive detected_transactions box
    final box = Hive.box('detected_transactions');
    await box.put(txn.id, txn.toMap());

    // Update state for UI
    _loadPendingTransactions();

    final settingsBox = Hive.box('settings');
    final bool autoApprove = settingsBox.get('autoApproveTransactions', defaultValue: false);

    if (autoApprove) {
      await approveTransaction(txn.id);
    }
  }

  /// Mark transaction as approved in Hive without triggering external callbacks
  static Future<void> markAsApproved(String id) async {
    final box = Hive.box('detected_transactions');
    final data = box.get(id);
    if (data == null) return;

    final txn = DetectedTransaction.fromMap(data);
    txn.status = 'approved';
    await box.put(id, txn.toMap());

    _loadPendingTransactions();
  }

  /// Manually approve and write detected transaction to official transactions list
  static Future<void> approveTransaction(String id, {
    String? category,
    int? accountId,
    String? notes,
  }) async {
    final box = Hive.box('detected_transactions');
    final data = box.get(id);
    if (data == null) return;

    final txn = DetectedTransaction.fromMap(data);
    txn.status = 'approved';
    await box.put(id, txn.toMap());

    _loadPendingTransactions();

    // Trigger saving to the active database / Firestore
    // This will be called via the callback handler in main.dart
    if (onTransactionApproved != null) {
      await onTransactionApproved!(txn, category: category, accountId: accountId, notes: notes);
    }
  }

  /// Discard a detected transaction
  static Future<void> dismissTransaction(String id) async {
    final box = Hive.box('detected_transactions');
    final data = box.get(id);
    if (data != null) {
      final txn = DetectedTransaction.fromMap(data);
      txn.status = 'dismissed';
      await box.put(id, txn.toMap());
    }
    _loadPendingTransactions();
  }

  /// Clear all stored detected transactions
  static Future<void> clearAll() async {
    final box = Hive.box('detected_transactions');
    await box.clear();
    _recentSignatures.clear();
    _loadPendingTransactions();
  }

  /// Simulate receiving a payment notification (for testing)
  static Future<void> simulateTransaction({
    double amount = 249.0,
    String payee = 'Swiggy',
    String category = 'Food',
    String accountName = 'Google Pay',
    DetectedTransactionType type = DetectedTransactionType.expense,
  }) async {
    final simulated = DetectedTransaction(
      id: '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}',
      amount: amount,
      payee: payee,
      category: category,
      accountName: accountName,
      type: type,
      timestamp: DateTime.now(),
      rawTitle: 'Google Pay',
      rawContent: 'Paid ₹$amount to $payee',
      packageName: 'com.google.android.apps.nbu.paisa.user',
      status: 'pending',
    );
    await _processDetectedTransaction(simulated);
  }

  /// Callback injected by main app to persist the approved transaction
  static Future<void> Function(
    DetectedTransaction txn, {
    String? category,
    int? accountId,
    String? notes,
  })? onTransactionApproved;

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }
}
