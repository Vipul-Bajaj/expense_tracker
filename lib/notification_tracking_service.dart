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

  /// Packages that send financial news, search results, stock alerts, social media, or ads
  /// that should NEVER be parsed as payment transactions.
  static final Set<String> blacklistedPackages = {
    'com.google.android.googlequicksearchbox', // Google App / Google Finance / Discover
    'com.google.android.apps.magazines', // Google News
    'com.android.chrome',
    'com.chrome.beta',
    'com.chrome.canary',
    'org.chromium.chrome',
    'com.google.android.youtube',
    'com.instagram.android',
    'com.facebook.katana',
    'com.facebook.orca',
    'com.twitter.android',
    'com.twitter.android.lite',
    'com.linkedin.android',
    'com.reddit.frontpage',
    'com.divum.MoneyControl',
    'com.zerodha.kite3',
    'com.nextbillion.groww',
    'com.upstox.pro',
    'com.angelbroking.angelwealth',
    'com.indwealth',
    'com.et.market',
    'com.investing.quotes',
    'com.tradingview.tradingviewapp',
    'com.tickertape.app',
  };

  /// Known payment and banking package names
  static final Map<String, String> knownPackages = {
    'com.google.android.apps.nbu.paisa.user': 'Google Pay',
    'com.phonepe.app': 'PhonePe',
    'net.one97.paytm': 'Paytm',
    'com.dreamplug.androidapp': 'CRED',
    'in.org.npci.upiapp': 'BHIM UPI',
    'in.amazon.mShop.android.shopping': 'Amazon Pay',
    'com.snapwork.hdfc': 'HDFC Bank',
    'com.hdfcbank.payzapp': 'HDFC PayZapp',
    'com.csam.icici.bank.imobile': 'ICICI Bank',
    'com.icicibank.pockets': 'ICICI Pockets',
    'com.axis.mobile': 'Axis Bank',
    'com.sbi.lotusintouch': 'SBI YONO',
    'com.msf.kbank.mobile': 'Kotak Bank',
    'com.indusind.mobile': 'IndusInd Bank',
    'com.bankofbaroda.mconnect': 'Bank of Baroda',
    'com.idfcfirstbank.optimus': 'IDFC First Bank',
    'com.jupiter.money': 'Jupiter',
    'com.fi.money': 'Fi Money',
    'com.onecard.app': 'OneCard',
    'com.google.android.apps.messaging': 'SMS',
    'com.samsung.android.messaging': 'SMS',
    'com.android.mms': 'SMS',
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

  /// Load pending detected transactions from Hive and automatically purge false positives
  static void _loadPendingTransactions() {
    try {
      final box = Hive.box('detected_transactions');
      final List<DetectedTransaction> list = [];
      final List<dynamic> invalidKeys = [];

      for (var key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          final item = DetectedTransaction.fromMap(val);
          // Auto-purge any items that originate from blacklisted packages or match negative keywords
          if (blacklistedPackages.contains(item.packageName) ||
              _containsNegativeKeywords('${item.rawTitle} ${item.rawContent}')) {
            invalidKeys.add(key);
            continue;
          }
          if (item.status == 'pending') {
            list.add(item);
          }
        }
      }

      // Purge invalid entries
      for (var k in invalidKeys) {
        box.delete(k);
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
    final fullText = '$title $content';

    // 1. Drop blacklisted packages immediately (Google App, News, Browsers, Social, Stock apps)
    if (blacklistedPackages.contains(pkg)) {
      debugPrint("Ignored notification from blacklisted package: $pkg");
      return;
    }

    // 2. Drop negative keywords immediately (stocks/shares up/down, offers, coupons, OTPs, reminders)
    if (_containsNegativeKeywords(fullText)) {
      debugPrint("Ignored notification matching negative keywords: $title - $content");
      return;
    }

    // 3. Must contain an explicit payment/banking verb
    if (!_hasValidTransactionVerbs(fullText)) {
      return;
    }

    // 4. If not a dedicated payment app, must contain banking context (a/c, account, card, bank, upi ref)
    bool isPaymentApp = knownPackages.containsKey(pkg);
    bool hasBankingIndicators = _hasBankingIndicators(fullText);

    if (!isPaymentApp && !hasBankingIndicators) {
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

  /// Check for negative keywords (stock movements, marketing offers, OTPs, due reminders)
  static bool _containsNegativeKeywords(String text) {
    final lower = text.toLowerCase();

    // Stock & market movements (e.g. Google Finance, News alerts)
    if (lower.contains('is up') ||
        lower.contains('rose to') ||
        lower.contains('jumped to') ||
        lower.contains('gained') ||
        lower.contains('is down') ||
        lower.contains('fell to') ||
        lower.contains('slipped to') ||
        lower.contains('dropped to') ||
        lower.contains('plunged') ||
        lower.contains('trading at') ||
        lower.contains('closed at') ||
        lower.contains('share price') ||
        lower.contains('shares of') ||
        lower.contains('stock price') ||
        lower.contains('stocks up') ||
        lower.contains('stocks down') ||
        lower.contains('all-time high') ||
        lower.contains('52-week') ||
        lower.contains('market alert') ||
        lower.contains('price alert') ||
        lower.contains('watchlist') ||
        lower.contains('sensex') ||
        lower.contains('nifty') ||
        lower.contains('nasdaq') ||
        lower.contains('target price') ||
        lower.contains('bullish') ||
        lower.contains('bearish')) {
      return true;
    }

    // Marketing, discounts, promotional offers
    if (lower.contains('flat rs') ||
        lower.contains('flat ₹') ||
        lower.contains('earn up to') ||
        lower.contains('cashback up to') ||
        lower.contains('win up to') ||
        lower.contains('win ₹') ||
        lower.contains('chance to win') ||
        lower.contains('upto rs') ||
        lower.contains('upto ₹') ||
        lower.contains('up to rs') ||
        lower.contains('up to ₹') ||
        lower.contains('use code') ||
        lower.contains('use coupon') ||
        lower.contains('apply code') ||
        lower.contains('discount of') ||
        lower.contains('voucher') ||
        lower.contains('coupon') ||
        lower.contains('special offer') ||
        lower.contains('limited offer') ||
        lower.contains('save up to') ||
        lower.contains('off on your next') ||
        lower.contains('% off') ||
        lower.contains('pre-approved') ||
        lower.contains('congratulations! you are eligible') ||
        lower.contains('avail loan') ||
        lower.contains('get a personal loan') ||
        lower.contains('instant personal loan')) {
      return true;
    }

    // OTP / Verification / Login codes
    if (lower.contains('otp') ||
        lower.contains('one time password') ||
        lower.contains('verification code') ||
        lower.contains('security code') ||
        lower.contains('secret code') ||
        lower.contains('do not share') ||
        lower.contains('don\'t share')) {
      return true;
    }

    // Future bill due reminders
    if (lower.contains('bill is due') ||
        lower.contains('bill due on') ||
        lower.contains('last date to pay') ||
        lower.contains('recharge due') ||
        lower.contains('bill generated') ||
        lower.contains('minimum amount due') ||
        lower.contains('pay before') ||
        lower.contains('upcoming payment')) {
      return true;
    }

    return false;
  }

  /// Must contain explicit action verbs indicating an actual debit, credit, or transfer
  static bool _hasValidTransactionVerbs(String text) {
    final lower = text.toLowerCase();
    return lower.contains('paid') ||
        lower.contains('debited') ||
        lower.contains('spent') ||
        lower.contains('credited') ||
        lower.contains('sent rs') ||
        lower.contains('sent inr') ||
        lower.contains('sent ₹') ||
        lower.contains('received rs') ||
        lower.contains('received inr') ||
        lower.contains('received ₹') ||
        lower.contains('withdrawn') ||
        lower.contains('auto-debit') ||
        lower.contains('auto debited') ||
        lower.contains('payment successful') ||
        lower.contains('payment of') ||
        lower.contains('payment to') ||
        lower.contains('transfer successful') ||
        lower.contains('transferred to') ||
        lower.contains('refund of') ||
        lower.contains('refund received') ||
        lower.contains('cashback received') ||
        lower.contains('money sent to') ||
        lower.contains('money received from');
  }

  /// Banking indicators for SMS or other non-payment app notifications
  static bool _hasBankingIndicators(String text) {
    final lower = text.toLowerCase();
    return lower.contains('a/c') ||
        lower.contains('acct') ||
        lower.contains('account') ||
        lower.contains('card ending') ||
        lower.contains('credit card') ||
        lower.contains('debit card') ||
        lower.contains('upi ref') ||
        lower.contains('upi txn') ||
        lower.contains('bank') ||
        lower.contains('vpa') ||
        lower.contains('bal:') ||
        lower.contains('avbl bal') ||
        lower.contains('avl bal');
  }

  /// Extract transaction data from notification title & body text
  static DetectedTransaction? parseTransactionText({
    required String title,
    required String content,
    String packageName = '',
  }) {
    final fullText = '$title $content';
    final lower = fullText.toLowerCase();

    // Check negative keywords (stock alerts, offers, reminders)
    if (_containsNegativeKeywords(fullText)) {
      return null;
    }

    // Must contain explicit transaction verb
    if (!_hasValidTransactionVerbs(fullText)) {
      return null;
    }

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
    final match = toPattern.firstMatch(content) ?? toPattern.firstMatch(title);
    if (match != null) {
      String candidate = match.group(1)?.trim() ?? '';
      final cLower = candidate.toLowerCase();
      // Exclude generic noise
      if (candidate.isNotEmpty &&
          !cLower.contains('account') &&
          !cLower.contains('card') &&
          !cLower.contains('bank') &&
          candidate.length > 1) {
        candidate = candidate
            .replaceAll(
                RegExp(r'(?:google pay|gpay|phonepe|paytm|bhim|cred)$',
                    caseSensitive: false),
                '')
            .trim();
        if (candidate.isNotEmpty) {
          return _capitalize(candidate);
        }
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
