import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:expense_tracker/biometric_service.dart';
import 'package:expense_tracker/currency_service.dart';
import 'package:expense_tracker/firebase_options.dart';

// --- ENCRYPTION SERVICE ---

class EncryptionService {
  // FIXED KEY for consistent decryption across devices without complex key exchange.
  // 32 characters for AES-256.
  static final _key = enc.Key.fromUtf8('ExpenseTrackerSecureKey2024Ver01');
  static final _encrypter = enc.Encrypter(enc.AES(_key));

  static String encrypt(String plainText) {
    if (plainText.isEmpty) return plainText;
    final iv = enc.IV.fromSecureRandom(16);
    final encrypted = _encrypter.encrypt(plainText, iv: iv);
    return "${iv.base64}:${encrypted.base64}";
  }

  static String decrypt(String encryptedText) {
    if (encryptedText.isEmpty) return encryptedText;
    try {
      final parts = encryptedText.split(':');
      if (parts.length != 2) return encryptedText; // Assume plain text fallback

      final iv = enc.IV.fromBase64(parts[0]);
      final encrypted = enc.Encrypted.fromBase64(parts[1]);
      return _encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      // If decryption fails, return original text (fallback for plaintext legacy data)
      return encryptedText;
    }
  }

  // Helper to handle double encryption
  static String encryptDouble(double value) => encrypt(value.toString());

  static double decryptDouble(dynamic value) {
    if (value is num) return value.toDouble(); // Legacy plain number
    if (value is String) {
      try {
        String decrypted = decrypt(value);
        return double.tryParse(decrypted) ?? 0.0;
      } catch (_) {
        return 0.0;
      }
    }
    return 0.0;
  }
}

class FinanceCalculator {
  static double calculateIncome(List<Transaction> transactions) {
    return transactions.fold(0.0, (sum, t) {
      if (t.type == TransactionType.income) return sum + t.amount;
      return sum;
    });
  }

  static double calculateExpense(List<Transaction> transactions) {
    return transactions.fold(0.0, (sum, t) {
      if (t.type == TransactionType.expense) return sum + t.amount;
      if (t.type == TransactionType.transfer) return sum + t.fee;
      return sum;
    });
  }

  static Map<String, double> calculateBreakdown({
    required List<Transaction> transactions,
    required List<Account> accounts,
    required bool byCategory,
  }) {
    final Map<String, double> breakdown = {};
    for (var t in transactions) {
      if (byCategory) {
        if (t.type == TransactionType.expense) {
          if (t.splits != null && t.splits!.isNotEmpty) {
            for (var split in t.splits!) {
              String key = split.subCategory != null && split.subCategory!.isNotEmpty
                  ? "${split.category} - ${split.subCategory}"
                  : split.category;
              breakdown[key] = (breakdown[key] ?? 0) + split.amount;
            }
          } else {
            String key = t.subCategory != null && t.subCategory!.isNotEmpty
                ? "${t.category} - ${t.subCategory}"
                : t.category;
            breakdown[key] = (breakdown[key] ?? 0) + t.amount;
          }
        } else if (t.type == TransactionType.transfer && t.fee > 0) {
          breakdown['Transfer Fees'] = (breakdown['Transfer Fees'] ?? 0) + t.fee;
        }
      } else {
        if (t.type == TransactionType.expense ||
            (t.type == TransactionType.transfer && t.fee > 0)) {
          final account = accounts.firstWhere((a) => a.id == t.sourceAccountId,
              orElse: () => Account(
                  id: -1,
                  name: 'Unknown',
                  balance: 0,
                  type: AccountType.cash,
                  createdDate: DateTime.now()));

          String key = account.type.name[0].toUpperCase() + account.type.name.substring(1);

          double amountToAdd = t.type == TransactionType.expense ? t.amount : t.fee;
          breakdown[key] = (breakdown[key] ?? 0) + amountToAdd;
        }
      }
    }
    return breakdown;
  }

  static List<MonthlyData> calculateMonthlyComparison(List<Transaction> transactions) {
    final Map<String, MonthlyData> monthlyMap = {};
    final now = DateTime.now();

    // Generate last 6 months
    for (int i = 5; i >= 0; i--) {
      final date = DateTime(now.year, now.month - i, 1);
      final key = DateFormat('MMM yyyy').format(date);
      monthlyMap[key] = MonthlyData(month: key, income: 0, expense: 0);
    }

    for (var t in transactions) {
      final key = DateFormat('MMM yyyy').format(t.date);
      if (monthlyMap.containsKey(key)) {
        if (t.type == TransactionType.income) {
          monthlyMap[key]!.income += t.amount;
        } else if (t.type == TransactionType.expense) {
          monthlyMap[key]!.expense += t.amount;
        } else if (t.type == TransactionType.transfer) {
          monthlyMap[key]!.expense += t.fee;
        }
      }
    }

    return monthlyMap.values.toList();
  }

  static Currency _getCurrencyConfig() {
    final box = Hive.box('settings');
    final currencyName = box.get('currency', defaultValue: 'inr');
    return Currency.values.firstWhere((c) => c.name == currencyName,
        orElse: () => Currency.inr);
  }

  static double _getEffectiveRate(Currency currency) {
    if (currency == Currency.inr) return 1.0;
    final box = Hive.box('settings');
    final String key = 'rate_${currency.name}';
    return box.get(key, defaultValue: currency.rate);
  }

  static double convertFromBase(double amount) {
    final currency = _getCurrencyConfig();
    final rate = _getEffectiveRate(currency);
    return amount * rate;
  }

  static double convertToBase(double amount) {
    final currency = _getCurrencyConfig();
    final rate = _getEffectiveRate(currency);
    return amount / rate;
  }

  static String formatCurrency(double amount) {
    final currency = _getCurrencyConfig();
    final convertedAmount = convertFromBase(amount);

    final format = NumberFormat.currency(
        locale: currency == Currency.inr ? 'en_IN' : 'en_US',
        symbol: currency.symbol,
        decimalDigits: currency == Currency.inr ? 0 : 2);
    return format.format(convertedAmount);
  }

  static String getSelectedCurrencySymbol() {
    return _getCurrencyConfig().symbol;
  }
}

class MonthlyData {
  final String month;
  double income;
  double expense;

  MonthlyData({required this.month, required this.income, required this.expense});
}

// --- 1. Data Models & Adapters ---

enum AccountType { bank, wallet, credit, cash }

enum TransactionType { expense, transfer, income }

// Added for Recurring Transactions
enum RecurrenceFrequency { none, daily, weekly, monthly, yearly }

enum Currency {
  inr(symbol: '₹', label: 'INR', rate: 1.0),
  usd(symbol: '\$', label: 'USD', rate: 0.012),
  eur(symbol: '€', label: 'EUR', rate: 0.011);

  final String symbol;
  final String label;
  final double rate; // Rate relative to INR (base)

  const Currency({required this.symbol, required this.label, required this.rate});
}

class Account {
  final int id;
  final String name;
  double balance;
  final AccountType type;
  final DateTime createdDate;

  Account({
    required this.id,
    required this.name,
    required this.balance,
    required this.type,
    required this.createdDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': EncryptionService.encrypt(name),
      'balance': EncryptionService.encryptDouble(balance),
      'type': type.index,
      'createdDate': Timestamp.fromDate(createdDate),
    };
  }

  factory Account.fromMap(Map<String, dynamic> map) {
    return Account(
      id: map['id'],
      name: EncryptionService.decrypt(map['name']),
      balance: EncryptionService.decryptDouble(map['balance']),
      type: AccountType.values[map['type']],
      createdDate: (map['createdDate'] as Timestamp).toDate(),
    );
  }

  IconData get icon {
    switch (type) {
      case AccountType.bank:
        return Icons.account_balance;
      case AccountType.wallet:
        return Icons.account_balance_wallet;
      case AccountType.credit:
        return Icons.credit_card;
      case AccountType.cash:
        return Icons.attach_money;
    }
  }

  Color get color {
    switch (type) {
      case AccountType.bank:
        return Colors.blue.shade700;
      case AccountType.wallet:
        return Colors.cyan.shade600;
      case AccountType.credit:
        return Colors.purple.shade600;
      case AccountType.cash:
        return Colors.green.shade600;
    }
  }
}

class TransactionSplit {
  final double amount;
  final String category;
  final String? subCategory;

  TransactionSplit(
      {required this.amount, required this.category, this.subCategory});

  Map<String, dynamic> toMap() {
    return {
      'amount': EncryptionService.encryptDouble(amount),
      'category': EncryptionService.encrypt(category),
      'subCategory':
      subCategory != null ? EncryptionService.encrypt(subCategory!) : null,
    };
  }

  factory TransactionSplit.fromMap(Map<String, dynamic> map) {
    return TransactionSplit(
      amount: EncryptionService.decryptDouble(map['amount']),
      category: EncryptionService.decrypt(map['category']),
      subCategory: map['subCategory'] != null
          ? EncryptionService.decrypt(map['subCategory'])
          : null,
    );
  }
}

class Transaction {
  final String id;
  final double amount;
  final double fee;
  final TransactionType type;
  final int sourceAccountId;
  final int? targetAccountId;
  final String category;
  final String? subCategory;
  final DateTime date;
  final List<TransactionSplit>? splits;
  final String? note;
  final RecurrenceFrequency recurrence; // Added field

  Transaction({
    required this.id,
    required this.amount,
    this.fee = 0.0,
    required this.type,
    required this.sourceAccountId,
    this.targetAccountId,
    required this.category,
    this.subCategory,
    required this.date,
    this.splits,
    this.note,
    this.recurrence = RecurrenceFrequency.none, // Default
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'amount': EncryptionService.encryptDouble(amount),
      'fee': EncryptionService.encryptDouble(fee),
      'type': type.index,
      'sourceAccountId': sourceAccountId,
      'targetAccountId': targetAccountId,
      'category': EncryptionService.encrypt(category),
      'subCategory':
      subCategory != null ? EncryptionService.encrypt(subCategory!) : null,
      'date': Timestamp.fromDate(date),
      'splits': splits?.map((s) => s.toMap()).toList(),
      'note': note != null ? EncryptionService.encrypt(note!) : null,
      'recurrence': recurrence.index, // Save enum index
    };
  }

  factory Transaction.fromMap(Map<String, dynamic> map) {
    return Transaction(
      id: map['id'],
      amount: EncryptionService.decryptDouble(map['amount']),
      fee: EncryptionService.decryptDouble(map['fee']),
      type: TransactionType.values[map['type']],
      sourceAccountId: map['sourceAccountId'],
      targetAccountId: map['targetAccountId'],
      category: EncryptionService.decrypt(map['category']),
      subCategory: map['subCategory'] != null
          ? EncryptionService.decrypt(map['subCategory'])
          : null,
      date: (map['date'] as Timestamp).toDate(),
      splits: map['splits'] != null
          ? (map['splits'] as List)
          .map((s) => TransactionSplit.fromMap(s))
          .toList()
          : null,
      note: map['note'] != null ? EncryptionService.decrypt(map['note']) : null,
      recurrence: map['recurrence'] != null
          ? RecurrenceFrequency.values[map['recurrence']]
          : RecurrenceFrequency.none,
    );
  }
}

// --- AUTH SERVICE ---

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: kIsWeb 
      ? '505413136406-r1tkrv2kotevtsl0vjgc6oqgfao19bvd.apps.googleusercontent.com' 
      : (Platform.isIOS ? DefaultFirebaseOptions.ios.iosClientId : null),
  );

  static User? get currentUser => _auth.currentUser;

  static Future<User?> signInWithGoogle() async {
    if (kIsWeb) {
      final GoogleAuthProvider googleProvider = GoogleAuthProvider();
      googleProvider.setCustomParameters({'prompt': 'select_account'});
      
      final UserCredential userCredential = await _auth.signInWithPopup(googleProvider);
      return userCredential.user;
    }

    await _googleSignIn.signOut(); // Force account picker on mobile

    final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null;

    final GoogleSignInAuthentication googleAuth =
    await googleUser.authentication;

    final OAuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final UserCredential userCredential =
    await _auth.signInWithCredential(credential);
    return userCredential.user;
  }

  static Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}

// --- MAIN ENTRY POINT ---

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase initialization failed: $e");
  }

  await Hive.initFlutter();

  // Adapters kept for migration purposes
  Hive.registerAdapter(AccountTypeAdapter());
  Hive.registerAdapter(TransactionTypeAdapter());
  Hive.registerAdapter(TransactionSplitAdapter());
  Hive.registerAdapter(AccountAdapter());
  Hive.registerAdapter(TransactionAdapter());

  await Hive.openBox('expenses_db');
  await Hive.openBox('settings');

  runApp(const ExpenseTrackerApp());
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box('settings').listenable(),
      builder: (context, box, _) {
        final themeModeName = box.get('themeMode', defaultValue: 'system');
        final ThemeMode themeMode = ThemeMode.values.firstWhere(
          (t) => t.name == themeModeName,
          orElse: () => ThemeMode.system,
        );

        return MaterialApp(
          title: 'Expense Tracker',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB),
              brightness: Brightness.light,
            ),
            textTheme: GoogleFonts.interTextTheme(),
            scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB),
              brightness: Brightness.dark,
            ),
            textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1E293B),
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
          ),
          home: const WelcomeScreen(),
        );
      },
    );
  }
}

// --- 2. Welcome Screen (UPDATED) ---

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Automatically check for logged in user on start
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAutoLogin();
    });
  }



  Future<void> _checkAutoLogin() async {
    final user = AuthService.currentUser;
    if (user != null) {
      // User is already logged in. Show branding for a moment then redirect.
      // 1.5 seconds delay for a smooth welcome experience
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;

      // Check for Biometric Lock
      final box = Hive.box('settings');
      final bool isBiometricEnabled = box.get('isBiometricEnabled', defaultValue: false);

      if (isBiometricEnabled) {
        final bool authenticated = await BiometricAuthService.authenticate();
        if (!authenticated) {
          // If failed or cancelled, stay on welcome screen or show error.
          // For security, checking again or just doing nothing (preventing access) is safest.
          if (mounted) {
             ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Authentication failed. Please try again.")),
            );
             // Re-attempting or showing a specific button to retry would be better UX, 
             // but for now we just stop the flow.
             return;
          }
        }
      }

      setState(() => _isLoading = true);
      await _migrateLocalData(user.uid);
      setState(() => _isLoading = false);

      if (mounted) _navigateToDashboard();
    }
  }

  void _navigateToDashboard() {
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const MainAppScaffold()));
  }

  Future<void> _migrateLocalData(String userId) async {
    final box = Hive.box('expenses_db');
    if (box.isEmpty) return;

    // Check if we have anything to migrate
    final accounts = List<Account>.from(
        box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);
    final transactions = List<Transaction>.from(
        box.get('transactions', defaultValue: [])?.cast<Transaction>() ?? []);
    final categories = box.get('categories');

    if (accounts.isEmpty && transactions.isEmpty && categories == null) {
      return;
    }

    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();

      // Migrate Accounts
      for (var acc in accounts) {
        final docRef = firestore
            .collection('users')
            .doc(userId)
            .collection('accounts')
            .doc(acc.id.toString());
        batch.set(docRef, acc.toMap());
      }

      // Migrate Transactions
      for (var txn in transactions) {
        final docRef = firestore
            .collection('users')
            .doc(userId)
            .collection('transactions')
            .doc(txn.id);
        batch.set(docRef, txn.toMap());
      }

      // Migrate Categories
      if (categories != null) {
        final docRef = firestore
            .collection('users')
            .doc(userId)
            .collection('settings')
            .doc('categories');
        batch.set(docRef, {'data': categories}, SetOptions(merge: true));
      }

      await batch.commit();
      await box.clear(); // Clear local data after successful migration
      debugPrint("Migration completed successfully.");
    } catch (e) {
      debugPrint("Error migrating data: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error migrating local data: $e")));
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final user = await AuthService.signInWithGoogle();

      if (user != null) {
        await _migrateLocalData(user.uid);
        setState(() => _isLoading = false);
        if (mounted) _navigateToDashboard();
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sign in cancelled')));
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint("Detailed error signing in with Google: $e");
      if (mounted) {
        String message = e.toString();
        if (message.contains('firebase_auth/admin-restricted-operation')) {
          message = "This operation is restricted. Check Firebase Console.";
        } else if (message.contains('firebase_auth/unauthorized-domain')) {
          message = "Domain not authorized. Check Firebase Console > Auth > Settings.";
        } else if (message.contains('popup-closed-by-user')) {
          message = "Sign-in popup closed before completion.";
        }
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sign in failed: $message'), duration: const Duration(seconds: 10)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only show "Sign in" buttons if NO user is detected (and we aren't loading/redirecting)
    // If a user exists, we are in the "splash" phase waiting to redirect.
    final user = AuthService.currentUser;
    final bool showLoginOptions = user == null && !_isLoading;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.wallet, size: 64, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(height: 40),

                Text(
                  'Expense Tracker',
                  style: GoogleFonts.inter(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                if (showLoginOptions)
                  Text(
                    'Control Your Money',
                    style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),

                if (!showLoginOptions) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Loading your finances...',
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant
                    ),
                  ),
                  const SizedBox(height: 32),
                  const CircularProgressIndicator(),
                ],

                const Spacer(),

                if (showLoginOptions) ...[
                  Text(
                    'Track expenses, income, manage accounts, and analyze your financial health.',
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  if (_isLoading)
                    const CircularProgressIndicator()
                  else
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _handleGoogleSignIn,
                        icon: const Icon(Icons.login),
                        label: Text('Sign in with Google',
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Theme.of(context).dividerColor),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  const SizedBox(height: 40),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 3. Main App Scaffold ---

class MainAppScaffold extends StatefulWidget {
  const MainAppScaffold({super.key});

  @override
  State<MainAppScaffold> createState() => _MainAppScaffoldState();
}

class _MainAppScaffoldState extends State<MainAppScaffold> {
  int _currentIndex = 0;
  bool _recurrenceChecked = false;

  void _checkRecurringTransactions(
      List<Transaction> transactions, List<Account> accounts, String userId) async {
    // ... existing recurring logic ...
    if (_recurrenceChecked) return;
    _recurrenceChecked = true;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final recurringTxns = transactions
        .where((t) => t.recurrence != RecurrenceFrequency.none)
        .toList();

    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();
    bool batchHasOps = false;

    // Create a map for quick account lookup
    final accountMap = {for (var a in accounts) a.id: a};

    for (var txn in recurringTxns) {
      DateTime nextDueDate = txn.date;

      // Calculate next due date based on frequency until we reach or pass today
      while (true) {
        switch (txn.recurrence) {
          case RecurrenceFrequency.daily:
            nextDueDate = nextDueDate.add(const Duration(days: 1));
            break;
          case RecurrenceFrequency.weekly:
            nextDueDate = nextDueDate.add(const Duration(days: 7));
            break;
          case RecurrenceFrequency.monthly:
          // Handle month overflow carefully
            int newMonth = nextDueDate.month + 1;
            int newYear = nextDueDate.year;
            if (newMonth > 12) {
              newMonth = 1;
              newYear++;
            }
            // Handle days like 31st Jan -> 28th Feb
            int lastDay = DateTime(newYear, newMonth + 1, 0).day;
            int newDay = min(txn.date.day, lastDay);
            nextDueDate = DateTime(newYear, newMonth, newDay);
            break;
          case RecurrenceFrequency.yearly:
          // Handle leap years
            if (txn.date.month == 2 && txn.date.day == 29) {
              // Check if next year is leap year, if not use 28th
              final isLeap = (nextDueDate.year + 1) % 4 == 0 && ((nextDueDate.year + 1) % 100 != 0 || (nextDueDate.year + 1) % 400 == 0);
              nextDueDate = DateTime(nextDueDate.year + 1, 2, isLeap ? 29 : 28);
            } else {
              nextDueDate = DateTime(nextDueDate.year + 1, nextDueDate.month, nextDueDate.day);
            }
            break;
          case RecurrenceFrequency.none:
            break;
        }

        // Stop if the calculated next due date is in the future (after today)
        if (nextDueDate.isAfter(today)) break;

        // Check if a transaction already exists for this recurrence on this specific date
        // Logic: Same Category, Amount, Type, and Date (Year, Month, Day)
        bool exists = transactions.any((t) =>
        t.amount == txn.amount &&
            t.category == txn.category &&
            t.type == txn.type &&
            t.date.year == nextDueDate.year &&
            t.date.month == nextDueDate.month &&
            t.date.day == nextDueDate.day);

        if (!exists) {
          // Create new transaction
          final newTxnId = DateTime.now().millisecondsSinceEpoch.toString() +
              Random().nextInt(1000).toString();

          final newTxn = Transaction(
            id: newTxnId,
            amount: txn.amount,
            fee: txn.fee,
            type: txn.type,
            sourceAccountId: txn.sourceAccountId,
            targetAccountId: txn.targetAccountId,
            category: txn.category,
            subCategory: txn.subCategory,
            date: nextDueDate, // The due date
            splits: txn.splits,
            note: "${txn.note ?? ''} (Recurring)",
            recurrence: RecurrenceFrequency.none, // New instance is not the parent
          );

          // Add to batch
          final txnRef = firestore
              .collection('users')
              .doc(userId)
              .collection('transactions')
              .doc(newTxn.id);
          batch.set(txnRef, newTxn.toMap());
          batchHasOps = true;

          // Update Account Balances
          final sourceAcc = accountMap[txn.sourceAccountId];
          if (sourceAcc != null) {
            double newBalance = sourceAcc.balance;
            if (txn.type == TransactionType.expense) {
              newBalance -= txn.amount;
            } else if (txn.type == TransactionType.transfer) {
              newBalance -= (txn.amount + txn.fee);
            } else if (txn.type == TransactionType.income) {
              newBalance += txn.amount;
            }
            // Update local object to reflect in next loop iteration if multiple recurring hit same account
            sourceAcc.balance = newBalance;

            final accRef = firestore.collection('users').doc(userId).collection('accounts').doc(sourceAcc.id.toString());
            batch.update(accRef, {'balance': EncryptionService.encryptDouble(newBalance)});
          }

          if (txn.type == TransactionType.transfer && txn.targetAccountId != null) {
            final targetAcc = accountMap[txn.targetAccountId];
            if (targetAcc != null) {
              targetAcc.balance += txn.amount;
              final targetRef = firestore.collection('users').doc(userId).collection('accounts').doc(targetAcc.id.toString());
              batch.update(targetRef, {'balance': EncryptionService.encryptDouble(targetAcc.balance)});
            }
          }
        }
      }
    }

    if (batchHasOps) {
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Recurring transactions generated automatically.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.currentUser;
    // If auth state changes to null, redirect to Welcome
    if (user == null) {
      Future.microtask(() {
        Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const WelcomeScreen()),
                (route) => false);
      });
      return const SizedBox();
    }

    final userDocRef =
    FirebaseFirestore.instance.collection('users').doc(user.uid);

    return StreamBuilder<QuerySnapshot>(
      stream: userDocRef.collection('accounts').snapshots(),
      builder: (context, accountsSnapshot) {
        final List<Account> accounts = accountsSnapshot.hasData
            ? accountsSnapshot.data!.docs
            .map((doc) =>
            Account.fromMap(doc.data() as Map<String, dynamic>))
            .toList()
            : [];

        return StreamBuilder<QuerySnapshot>(
          stream: userDocRef.collection('transactions').snapshots(),
          builder: (context, transactionsSnapshot) {
            final List<Transaction> transactions = transactionsSnapshot.hasData
                ? transactionsSnapshot.data!.docs
                .map((doc) =>
                Transaction.fromMap(doc.data() as Map<String, dynamic>))
                .toList()
                : [];

            // Check for recurring transactions once data is loaded
            if (transactions.isNotEmpty && accounts.isNotEmpty && !_recurrenceChecked) {
              Future.microtask(() => _checkRecurringTransactions(transactions, accounts, user.uid));
            }

            return StreamBuilder<DocumentSnapshot>(
              stream: userDocRef
                  .collection('settings')
                  .doc('categories')
                  .snapshots(),
              builder: (context, categoriesSnapshot) {
                Map<String, List<String>> categories = {
                  'Food': ['Groceries', 'Restaurant', 'Snacks'],
                  'Bills': [
                    'Rent',
                    'Electricity',
                    'Internet',
                    'Water',
                    'Phone'
                  ],
                  'Transport': ['Fuel', 'Taxi', 'Public', 'Repair'],
                  'Shopping': ['Clothes', 'Electronics', 'Home', 'Gifts'],
                  'Personal Care': [
                    'Haircut',
                    'Beard',
                    'Salon',
                    'Spa',
                    'Cosmetics'
                  ],
                  'Skill Dev': [
                    'Dance Class',
                    'Violin Class',
                    'Course',
                    'Workshop'
                  ],
                  'Investment': [
                    'Mutual Funds',
                    'Stocks',
                    'FD',
                    'Gold',
                    'SIP'
                  ],
                  'Health': ['Medicine', 'Doctor', 'Insurance'],
                  'Entmt': ['Movies', 'Games', 'Events', 'Date'],
                };

                if (categoriesSnapshot.hasData &&
                    categoriesSnapshot.data != null &&
                    categoriesSnapshot.data!.exists) {
                  final data =
                  categoriesSnapshot.data!.data() as Map<String, dynamic>;
                  if (data.containsKey('data')) {
                    categories = (data['data'] as Map).map((k, v) => MapEntry(
                        k.toString(),
                        (v as List).map((e) => e.toString()).toList()));
                  }
                }

                return ValueListenableBuilder(
                  valueListenable: Hive.box('settings').listenable(),
                  builder: (context, box, _) {
                    final List<Widget> pages = [
                      DashboardTab(accounts: accounts, transactions: transactions),
                      TransactionsTab(
                          transactions: transactions,
                          accounts: accounts,
                          categories: categories),
                      AccountsTab(accounts: accounts, transactions: transactions), // Passed transactions
                      ReportsTab(accounts: accounts, transactions: transactions),
                      CategoriesTab(categories: categories),
                    ];

                    return Scaffold(
                      body: pages[_currentIndex],
                      bottomNavigationBar: BottomNavigationBar(
                        currentIndex: _currentIndex,
                        onTap: (idx) => setState(() => _currentIndex = idx),
                        selectedItemColor: Theme.of(context).colorScheme.primary,
                        unselectedItemColor: Theme.of(context).colorScheme.onSurfaceVariant,
                        showUnselectedLabels: true,
                        type: BottomNavigationBarType.fixed,
                        items: const [
                          BottomNavigationBarItem(
                              icon: Icon(Icons.dashboard_outlined),
                              activeIcon: Icon(Icons.dashboard),
                              label: 'Dashboard'),
                          BottomNavigationBarItem(
                              icon: Icon(Icons.history_outlined),
                              activeIcon: Icon(Icons.history),
                              label: 'History'),
                          BottomNavigationBarItem(
                              icon: Icon(Icons.account_balance_wallet_outlined),
                              activeIcon: Icon(Icons.account_balance_wallet),
                              label: 'Accounts'),
                          BottomNavigationBarItem(
                              icon: Icon(Icons.bar_chart),
                              activeIcon: Icon(Icons.bar_chart),
                              label: 'Reports'),
                          BottomNavigationBarItem(
                              icon: Icon(Icons.category_outlined),
                              activeIcon: Icon(Icons.category),
                              label: 'Categories'),
                        ],
                      ),
                      floatingActionButton: _currentIndex == 0
                          ? FloatingActionButton(
                        onPressed: () {
                          if (accounts.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Please add an account first (Accounts Tab)!'),
                                    backgroundColor: Colors.red));
                            return;
                          }
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) =>
                                AddTransactionSheet(accounts: accounts),
                          );
                        },
                        backgroundColor: const Color(0xFF2563EB),
                        child: const Icon(Icons.add, color: Colors.white),
                      )
                          : null,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

// --- 4. Dashboard Tab (UPDATED) ---

class DashboardTab extends StatefulWidget {
  final List<Account> accounts;
  final List<Transaction> transactions;

  const DashboardTab(
      {super.key, required this.accounts, required this.transactions});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  DateTime _currentMonth = DateTime.now();
  final User? _user = AuthService.currentUser;


  void _changeMonth(int offset) {
    setState(() {
      _currentMonth =
          DateTime(_currentMonth.year, _currentMonth.month + offset);
    });
  }

  void _signOut(BuildContext context) async {
    await AuthService.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const WelcomeScreen()),
            (route) => false,
      );
    }
  }

  void _switchAccount(BuildContext context) async {
    // 1. Sign out the current user
    await AuthService.signOut();

    // 2. Navigate back to Welcome Screen
    // The welcome screen will see user is null, and show "Sign In" button.
    // The user can then click "Sign in with Google" which will open the account picker
    // (because signOut() calls googleSignIn.signOut()).
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const WelcomeScreen()),
            (route) => false,
      );
    }
  }

  void _showProfileOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (_user != null) ...[
                CircleAvatar(
                  radius: 36,
                  backgroundColor: Colors.blue.shade50,
                  backgroundImage: _user!.photoURL != null
                      ? NetworkImage(_user!.photoURL!)
                      : null,
                  child: _user!.photoURL == null
                      ? Text(_user!.displayName?[0] ?? "U",
                      style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blue.shade700))
                      : null,
                ),
                const SizedBox(height: 16),
                Text(
                  _user!.displayName ?? 'User',
                  style: GoogleFonts.inter(
                      fontSize: 20, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
                ),
                Text(
                  _user!.email ?? '',
                  style: GoogleFonts.inter(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                ),
                const SizedBox(height: 24),
                const Divider(height: 1),
                const SizedBox(height: 12),
              ],



              // Biometric Toggle
              StatefulBuilder(
                builder: (context, setSheetState) {
                  final box = Hive.box('settings');
                  bool isEnabled = box.get('isBiometricEnabled', defaultValue: false);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: isEnabled ? Colors.green.shade50 : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8)
                      ),
                      child: Icon(
                          Icons.fingerprint,
                          color: isEnabled ? Colors.green.shade600 : Colors.grey.shade600
                      ),
                    ),
                    title: Text('Biometric Lock',
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.blueGrey.shade800)),
                    subtitle: Text(
                        isEnabled ? 'App is locked on startup' : 'Enable to protect your data',
                        style: GoogleFonts.inter(fontSize: 12, color: Colors.blueGrey.shade400)),
                    trailing: Switch(
                      value: isEnabled,
                      activeColor: const Color(0xFF2563EB),
                      onChanged: (val) async {
                        if (val) {
                          // Verify biometrics before enabling
                          bool canCheck = await BiometricAuthService.canCheckBiometrics();
                          if (!canCheck) {
                            if (context.mounted) {
                               ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Biometrics not available on this device")),
                              );
                            }
                            return;
                          }
                          bool authenticated = await BiometricAuthService.authenticate();
                          if (authenticated) {
                            await box.put('isBiometricEnabled', true);
                            setSheetState(() {});
                          }
                        } else {
                          await box.put('isBiometricEnabled', false);
                          setSheetState(() {});
                        }
                      },
                    ),
                  );
                }
              ),
              const SizedBox(height: 8),

              StatefulBuilder(
                builder: (context, setSheetState) {
                  final box = Hive.box('settings');
                  String currentCurrency = box.get('currency', defaultValue: 'inr');

                  final currencyListTile = ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8)
                      ),
                      child: Icon(
                          Icons.payments_outlined,
                          color: Colors.orange.shade600
                      ),
                    ),
                    title: Text('Reference Currency',
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface)),
                    subtitle: Text(
                        'Display amounts in ${currentCurrency.toUpperCase()}',
                        style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    trailing: DropdownButton<String>(
                      value: currentCurrency,
                      underline: const SizedBox(),
                      items: Currency.values.map((c) {
                        return DropdownMenuItem(
                          value: c.name,
                          child: Text(c.label),
                        );
                      }).toList(),
                      onChanged: (val) async {
                        if (val != null) {
                          await box.put('currency', val);
                          setSheetState(() {});
                        }
                      },
                    ),
                  );

                  String currentThemeMode = box.get('themeMode', defaultValue: 'system');

                  final themeListTile = ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(8)
                      ),
                      child: Icon(
                          currentThemeMode == 'dark' ? Icons.dark_mode_outlined : (currentThemeMode == 'light' ? Icons.light_mode_outlined : Icons.brightness_auto_outlined),
                          color: Colors.purple.shade600
                      ),
                    ),
                    title: Text('App Theme',
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface)),
                    subtitle: Text(
                        'Current: ${currentThemeMode[0].toUpperCase()}${currentThemeMode.substring(1)}',
                        style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    trailing: DropdownButton<String>(
                      value: currentThemeMode,
                      underline: const SizedBox(),
                      items: ['light', 'dark', 'system'].map((m) {
                        return DropdownMenuItem(
                          value: m,
                          child: Text(m[0].toUpperCase() + m.substring(1)),
                        );
                      }).toList(),
                      onChanged: (val) async {
                        if (val != null) {
                          await box.put('themeMode', val);
                          setSheetState(() {});
                        }
                      },
                    ),
                  );

                  return Column(
                    children: [
                      currencyListTile,
                      themeListTile,
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(8)
                          ),
                          child: Icon(
                              Icons.sync,
                              color: Colors.blue.shade600
                          ),
                        ),
                        title: Text('Update Rates',
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurface)),
                        subtitle: Text(
                            'Last updated: ${CurrencyService.getLastUpdatedText()}',
                            style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        trailing: IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () async {
                            final success = await CurrencyService.updateRates();
                            if (success) {
                              setSheetState(() {});
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Rates updated successfully')),
                                );
                              }
                            } else {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Failed to update rates')),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  );
                }
              ),
              const SizedBox(height: 8),

              // Enhanced Switch Account Option
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8)
                  ),
                  child: const Icon(Icons.switch_account_outlined, color: Color(0xFF2563EB)),
                ),
                title: Text('Switch Account',
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface)),
                subtitle: Text('Login with a different email',
                    style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchAccount(context);
                },
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),

              const SizedBox(height: 8),

              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8)
                  ),
                  child: Icon(Icons.logout, color: Colors.red.shade600),
                ),
                title: Text('Sign Out',
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _signOut(context);
                },
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

  @override
  Widget build(BuildContext context) {
    final monthlyTransactions = widget.transactions.where((t) {
      return t.date.year == _currentMonth.year &&
          t.date.month == _currentMonth.month;
    }).toList();
    monthlyTransactions.sort((a, b) => b.date.compareTo(a.date));

    final double monthlyIncome = FinanceCalculator.calculateIncome(monthlyTransactions);
    final double monthlyExpense = FinanceCalculator.calculateExpense(monthlyTransactions);

    final double monthlyTotal = monthlyIncome - monthlyExpense;

    return Scaffold(
      appBar: AppBar(
        title: Text('Dashboard',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        actions: [
          if (_user != null) ...[
            GestureDetector(
              onTap: () => _showProfileOptions(context),
              child: Container(
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.blue.shade100, width: 2),
                ),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.blue.shade50,
                  backgroundImage: _user!.photoURL != null
                      ? NetworkImage(_user!.photoURL!)
                      : null,
                  child: _user!.photoURL == null
                      ? Icon(Icons.person, size: 20, color: Colors.blue.shade700)
                      : null,
                ),
              ),
            ),
          ] else ...[
            TextButton(
              onPressed: () => _signOut(context),
              child: const Text("Sign In"),
            )
          ]
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 5))
                ]),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                        onPressed: () => _changeMonth(-1),
                        icon: const Icon(Icons.chevron_left)),
                    Text(DateFormat('MMMM yyyy').format(_currentMonth),
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface)),
                    IconButton(
                        onPressed: () => _changeMonth(1),
                        icon: const Icon(Icons.chevron_right)),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Total Balance',
                    style: GoogleFonts.inter(
                        color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
                const SizedBox(height: 4),
                Text(FinanceCalculator.formatCurrency(monthlyTotal),
                    style: GoogleFonts.inter(
                        color: monthlyTotal >= 0
                            ? Theme.of(context).colorScheme.onSurface
                            : Colors.red.shade600,
                        fontSize: 36,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.arrow_downward,
                                size: 16, color: Colors.green),
                            const SizedBox(width: 4),
                            Text('Income',
                                style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ],
                        ),
                        Text(FinanceCalculator.formatCurrency(monthlyIncome),
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.green)),
                      ],
                    ),
                    Container(
                        height: 30, width: 1, color: Theme.of(context).dividerColor),
                    Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.arrow_upward,
                                size: 16, color: Colors.red),
                            const SizedBox(width: 4),
                            Text('Expense',
                                style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ],
                        ),
                        Text(FinanceCalculator.formatCurrency(monthlyExpense),
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.red)),
                      ],
                    ),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('RECENT TRANSACTIONS',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          if (monthlyTransactions.isEmpty)
            Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('No transactions in this month',
                        style: GoogleFonts.inter(
                            color: Theme.of(context).colorScheme.onSurfaceVariant))))
          else
            ...monthlyTransactions.take(10).map((txn) =>
                TransactionItem(transaction: txn, accounts: widget.accounts)),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// --- 4.5. Transactions Tab (NEW) ---

class TransactionsTab extends StatefulWidget {
  final List<Transaction> transactions;
  final List<Account> accounts;
  final Map<String, List<String>> categories;

  const TransactionsTab({
    super.key,
    required this.transactions,
    required this.accounts,
    required this.categories,
  });

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  DateTimeRange? _selectedDateRange;
  String? _selectedCategory;
  String? _selectedSubCategory;
  TransactionType? _selectedType;
  int? _selectedAccountId;
  bool _isSearchVisible = false;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    _selectedDateRange = DateTimeRange(start: start, end: end);
  }

  void _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _selectedDateRange,
    );
    if (picked != null) {
      setState(() {
        _selectedDateRange = picked;
      });
    }
  }

  void _showFilterSheet() {
    // Sort lists for display
    final sortedAccounts = List<Account>.from(widget.accounts)
      ..sort((a, b) => a.name.compareTo(b.name));
    final sortedCategories = widget.categories.keys.toList()..sort();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(builder: (context, setModalState) {
        // Sort subcategories if category selected
        List<String>? sortedSubCategories;
        if (_selectedCategory != null &&
            widget.categories[_selectedCategory] != null) {
          sortedSubCategories =
          List<String>.from(widget.categories[_selectedCategory]!)..sort();
        }

        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Filter Transactions",
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold, fontSize: 18)),
                  TextButton(
                    onPressed: () {
                      setModalState(() {
                        _selectedCategory = null;
                        _selectedSubCategory = null;
                        _selectedType = null;
                        _selectedAccountId = null;
                      });
                      setState(() {
                        _selectedCategory = null;
                        _selectedSubCategory = null;
                        _selectedType = null;
                        _selectedAccountId = null;
                      });
                      Navigator.pop(context);
                    },
                    child: const Text("Clear All"),
                  )
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<TransactionType>(
                value: _selectedType,
                decoration: InputDecoration(
                  labelText: "Type",
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text("All Types")),
                  ...TransactionType.values.map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(
                          t.name[0].toUpperCase() + t.name.substring(1)))),
                ],
                onChanged: (val) {
                  setModalState(() => _selectedType = val);
                  setState(() => _selectedType = val);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                value: _selectedAccountId,
                decoration: InputDecoration(
                  labelText: "Account",
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text("All Accounts")),
                  ...sortedAccounts.map((a) =>
                      DropdownMenuItem(value: a.id, child: Text(a.name))),
                ],
                onChanged: (val) {
                  setModalState(() => _selectedAccountId = val);
                  setState(() => _selectedAccountId = val);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _selectedCategory,
                decoration: InputDecoration(
                  labelText: "Category",
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text("All Categories")),
                  ...sortedCategories
                      .map((c) => DropdownMenuItem(value: c, child: Text(c))),
                ],
                onChanged: (val) {
                  setModalState(() {
                    _selectedCategory = val;
                    _selectedSubCategory = null;
                  });
                  setState(() {
                    _selectedCategory = val;
                    _selectedSubCategory = null;
                  });
                },
              ),
              if (_selectedCategory != null && sortedSubCategories != null) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _selectedSubCategory,
                  decoration: InputDecoration(
                    labelText: "Sub-Category",
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text("All Sub-Categories")),
                    ...sortedSubCategories.map(
                            (s) => DropdownMenuItem(value: s, child: Text(s))),
                  ],
                  onChanged: (val) {
                    setModalState(() => _selectedSubCategory = val);
                    setState(() => _selectedSubCategory = val);
                  },
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text("Apply Filters",
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              )
            ],
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.transactions.where((t) {
      if (_selectedDateRange != null) {
        final start = DateTime(_selectedDateRange!.start.year,
            _selectedDateRange!.start.month, _selectedDateRange!.start.day);
        final end = DateTime(
            _selectedDateRange!.end.year,
            _selectedDateRange!.end.month,
            _selectedDateRange!.end.day,
            23,
            59,
            59);
        if (t.date.isBefore(start) || t.date.isAfter(end)) {
          return false;
        }
      }

      if (_selectedType != null && t.type != _selectedType) {
        return false;
      }

      if (_selectedAccountId != null) {
        bool matches = t.sourceAccountId == _selectedAccountId ||
            t.targetAccountId == _selectedAccountId;
        if (!matches) return false;
      }

      if (_searchCtrl.text.isNotEmpty) {
        final query = _searchCtrl.text.toLowerCase();
        final noteMatch = t.note?.toLowerCase().contains(query) ?? false;
        final catMatch = t.category.toLowerCase().contains(query);
        final subMatch = t.subCategory?.toLowerCase().contains(query) ?? false;
        if (!noteMatch && !catMatch && !subMatch) return false;
      }

      if (_selectedCategory == null) return true;

      if (t.splits != null && t.splits!.isNotEmpty) {
        return t.splits!.any((s) =>
        s.category == _selectedCategory &&
            (_selectedSubCategory == null ||
                s.subCategory == _selectedSubCategory));
      }

      if (t.category == _selectedCategory) {
        if (_selectedSubCategory == null) return true;
        return t.subCategory == _selectedSubCategory;
      }

      return false;
    }).toList();

    filtered.sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(
        title: _isSearchVisible
            ? TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Search transactions...",
            border: InputBorder.none,
          ),
          onChanged: (val) => setState(() {}),
        )
            : Text("Transactions",
            style: GoogleFonts.inter(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface)),
        actions: [
          IconButton(
            icon: Icon(_isSearchVisible ? Icons.close : Icons.search),
            color: Colors.blueGrey.shade700,
            onPressed: () {
              setState(() {
                _isSearchVisible = !_isSearchVisible;
                if (!_isSearchVisible) _searchCtrl.clear();
              });
            },
          ),
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.filter_list),
                color: (_selectedCategory != null ||
                    _selectedType != null ||
                    _selectedAccountId != null)
                    ? const Color(0xFF2563EB)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                onPressed: _showFilterSheet,
              ),
              if (_selectedCategory != null ||
                  _selectedType != null ||
                  _selectedAccountId != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                )
            ],
          )
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border:
              Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _pickDateRange,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.calendar_today,
                              size: 14, color: Colors.blue),
                          const SizedBox(width: 8),
                          Text(
                            _selectedDateRange != null
                                ? "${DateFormat('dd MMM').format(_selectedDateRange!.start)} - ${DateFormat('dd MMM yyyy').format(_selectedDateRange!.end)}"
                                : "All Time",
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_selectedDateRange != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Clear Date Filter",
                    onPressed: () => setState(() {
                      _selectedDateRange = null;
                    }),
                  )
              ],
            ),
          ),
          if (_selectedCategory != null ||
              _selectedType != null ||
              _selectedAccountId != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              color: Colors.blue.shade50,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Icon(Icons.filter_alt,
                        size: 14, color: Colors.blue.shade700),
                    const SizedBox(width: 8),
                    if (_selectedType != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(
                              _selectedType!.name[0].toUpperCase() +
                                  _selectedType!.name.substring(1),
                              style: const TextStyle(fontSize: 10)),
                          deleteIcon: const Icon(Icons.close, size: 12),
                          onDeleted: () =>
                              setState(() => _selectedType = null),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    if (_selectedAccountId != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(
                              widget.accounts
                                  .firstWhere(
                                      (a) => a.id == _selectedAccountId,
                                  orElse: () => Account(
                                      id: -1,
                                      name: 'Unknown',
                                      balance: 0,
                                      type: AccountType.cash,
                                      createdDate: DateTime.now()))
                                  .name,
                              style: const TextStyle(fontSize: 10)),
                          deleteIcon: const Icon(Icons.close, size: 12),
                          onDeleted: () =>
                              setState(() => _selectedAccountId = null),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    if (_selectedCategory != null)
                      Chip(
                        label: Text(
                            "$_selectedCategory ${_selectedSubCategory != null ? '> $_selectedSubCategory' : ''}",
                            style: const TextStyle(fontSize: 10)),
                        deleteIcon: const Icon(Icons.close, size: 12),
                        onDeleted: () => setState(() {
                          _selectedCategory = null;
                          _selectedSubCategory = null;
                        }),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() {
                        _selectedCategory = null;
                        _selectedSubCategory = null;
                        _selectedType = null;
                        _selectedAccountId = null;
                      }),
                      child: Text("Clear All",
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              color: Colors.blue.shade800,
                              fontWeight: FontWeight.bold)),
                    )
                  ],
                ),
              ),
            ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.search_off,
                        size: 48, color: Colors.blueGrey.shade200),
                    const SizedBox(height: 16),
                    Text("No transactions found",
                        style: GoogleFonts.inter(
                            color: Colors.blueGrey.shade400)),
                  ],
                ))
                : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: filtered.length,
              itemBuilder: (ctx, i) => TransactionItem(
                  transaction: filtered[i], accounts: widget.accounts),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 5. Accounts Tab (UPDATED) ---

class AccountsTab extends StatelessWidget {
  final List<Account> accounts;
  final List<Transaction> transactions;

  const AccountsTab(
      {super.key, required this.accounts, required this.transactions});

  void _showAccountSheet(BuildContext context, {Account? account}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddAccountSheet(existingAccount: account),
    );
  }

  void _showAccountDetails(BuildContext context, Account account) {
    // Filter transactions for this account
    final accountTxns = transactions.where((t) {
      return t.sourceAccountId == account.id || t.targetAccountId == account.id;
    }).toList();

    // Sort by date desc
    accountTxns.sort((a, b) => b.date.compareTo(a.date));

    double totalCredit = 0;
    double totalDebit = 0;

    for (var t in accountTxns) {
      if (t.type == TransactionType.income) {
        totalCredit += t.amount;
      } else if (t.type == TransactionType.expense) {
        totalDebit += t.amount;
      } else if (t.type == TransactionType.transfer) {
        if (t.sourceAccountId == account.id) {
          totalDebit += (t.amount + t.fee);
        } else if (t.targetAccountId == account.id) {
          totalCredit += t.amount;
        }
      }
    }

    final double openingBalance = account.balance - (totalCredit - totalDebit);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Text(account.name,
                  style: GoogleFonts.inter(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _summaryColumn("Opening", openingBalance, Colors.grey),
                    _summaryColumn("Credits", totalCredit, Colors.green),
                    _summaryColumn("Debits", totalDebit, Colors.red),
                    _summaryColumn("Current", account.balance, Colors.blue),
                  ],
                ),
              ),
              const Divider(height: 32),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: accountTxns.length,
                  itemBuilder: (ctx, i) => TransactionItem(
                      transaction: accountTxns[i], accounts: accounts),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryColumn(String label, double amount, Color color) {
    return Column(
      children: [
        Text(label,
            style: GoogleFonts.inter(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          FinanceCalculator.formatCurrency(amount),
          style: GoogleFonts.inter(
              fontWeight: FontWeight.bold, color: color, fontSize: 14),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sort accounts alphabetically
    final sortedAccounts = List<Account>.from(accounts)
      ..sort((a, b) => a.name.compareTo(b.name));

    // Group accounts by type
    final Map<AccountType, List<Account>> groupedAccounts = {};
    for (var type in AccountType.values) {
      groupedAccounts[type] = [];
    }
    for (var acc in sortedAccounts) {
      groupedAccounts[acc.type]?.add(acc);
    }

    return Scaffold(
      appBar: AppBar(
          title: Text('Accounts',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface))),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAccountSheet(context),
        backgroundColor: const Color(0xFF2563EB),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: accounts.isEmpty
          ? Center(
          child: Text("No accounts yet",
              style: GoogleFonts.inter(color: Colors.grey)))
          : ListView(
        padding: const EdgeInsets.all(20),
        children: AccountType.values.expand((type) {
          final typeAccounts = groupedAccounts[type]!;
          if (typeAccounts.isEmpty) return <Widget>[];
          return [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                type.name[0].toUpperCase() + type.name.substring(1),
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            ...typeAccounts.map((acc) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GestureDetector(
                onTap: () => _showAccountDetails(context, acc),
                onLongPress: () => _showAccountSheet(context, account: acc),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border:
                      Border.all(color: Theme.of(context).dividerColor)),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: acc.color.withOpacity(0.1),
                            shape: BoxShape.circle),
                        child: Icon(acc.icon,
                            color: acc.color, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Text(acc.name,
                                style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurface)),
                            // Removed type text since it's now a section header
                          ],
                        ),
                      ),
                      Text(
                        FinanceCalculator.formatCurrency(acc.balance),
                        style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
              ),
            ))
          ];
        }).toList(),
      ),
    );
  }
}

// --- 6. Reports Tab ---

class ReportsTab extends StatefulWidget {
  final List<Account> accounts;
  final List<Transaction> transactions;

  const ReportsTab(
      {super.key, required this.accounts, required this.transactions});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

enum ReportType { category, accountType }

class _ReportsTabState extends State<ReportsTab> {
  DateTime _currentMonth = DateTime.now();
  bool _isPieChart = false;
  ReportType _reportType = ReportType.category;


  void _changeMonth(int offset) {
    setState(() {
      _currentMonth =
          DateTime(_currentMonth.year, _currentMonth.month + offset);
    });
  }

  Future<void> _exportData() async {
    if (widget.transactions.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("No data to export")));
      return;
    }
    try {
      StringBuffer csv = StringBuffer();
      csv.writeln(
          "Date,Type,Category,SubCategory,Amount,Fee,Source Account,Target Account,Splits/Notes");
      for (var t in widget.transactions) {
        String date = DateFormat('yyyy-MM-dd').format(t.date);
        String type = t.type.name[0].toUpperCase() + t.type.name.substring(1);
        String category = t.category.replaceAll(',', ' ');
        String sub = (t.subCategory ?? "").replaceAll(',', ' ');
        String amount = t.amount.toStringAsFixed(2);
        String fee = t.fee.toStringAsFixed(2);
        String source = widget.accounts
            .firstWhere((a) => a.id == t.sourceAccountId,
            orElse: () => Account(
                id: -1,
                name: 'Unknown',
                balance: 0,
                type: AccountType.cash,
                createdDate: DateTime.now()))
            .name;
        String target = t.targetAccountId != null
            ? widget.accounts
            .firstWhere((a) => a.id == t.targetAccountId!,
            orElse: () => Account(
                id: -1,
                name: 'Unknown',
                balance: 0,
                type: AccountType.cash,
                createdDate: DateTime.now()))
            .name
            : "";
        String details = t.splits != null && t.splits!.isNotEmpty
            ? t.splits!
            .map(
                (s) => "${s.category}:${s.subCategory ?? ''} (${s.amount})")
            .join(" | ")
            : "";

        if (t.note != null && t.note!.isNotEmpty) {
          details = details.isEmpty
              ? "Note: ${t.note}"
              : "$details | Note: ${t.note}";
        }

        csv.writeln(
            "$date,$type,$category,$sub,$amount,$fee,$source,$target,$details");
      }
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/expenses_export.csv';
      final file = File(path);
      await file.writeAsString(csv.toString());
      await Share.shareXFiles([XFile(path)], text: 'Expense Report');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Export failed: $e"), backgroundColor: Colors.red));
    }
  }

  Color _getColor(int index) {
    const colors = [
      Color(0xFF3B82F6), // Blue
      Color(0xFFEF4444), // Red
      Color(0xFF10B981), // Green
      Color(0xFFF59E0B), // Amber
      Color(0xFF8B5CF6), // Violet
      Color(0xFFEC4899), // Pink
      Color(0xFF06B6D4), // Cyan
      Color(0xFF6366F1), // Indigo
      Color(0xFFF97316), // Orange
      Color(0xFF64748B), // Slate
    ];
    return colors[index % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final monthlyTransactions = widget.transactions.where((t) {
      return t.date.year == _currentMonth.year &&
          t.date.month == _currentMonth.month;
    }).toList();

    final double monthlyExpense = FinanceCalculator.calculateExpense(monthlyTransactions);

    final Map<String, double> breakdown = FinanceCalculator.calculateBreakdown(
      transactions: monthlyTransactions,
      accounts: widget.accounts,
      byCategory: _reportType == ReportType.category,
    );
    final sortedBreakdown = Map.fromEntries(
        breakdown.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));

    return Scaffold(
      appBar: AppBar(
          title: Text('Reports',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        actions: [
          IconButton(
            onPressed: () => setState(() => _isPieChart = !_isPieChart),
            icon: Icon(_isPieChart ? Icons.list : Icons.pie_chart,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            tooltip: _isPieChart ? 'Switch to List' : 'Switch to Pie Chart',
          ),
          TextButton.icon(
            onPressed: _exportData,
            icon: const Icon(Icons.download, size: 18),
            label: const Text("Export CSV"),
            style:
            TextButton.styleFrom(foregroundColor: const Color(0xFF2563EB)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    onPressed: () => _changeMonth(-1),
                    icon: const Icon(Icons.chevron_left)),
                Text(DateFormat('MMMM yyyy').format(_currentMonth),
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface)),
                IconButton(
                    onPressed: () => _changeMonth(1),
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Last 6 Months Comparison",
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 4),
                Text("Income (Green) vs Expense (Red)",
                    style: GoogleFonts.inter(
                        fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 32),
                SizedBox(
                  height: 150,
                  width: double.infinity,
                  child: (() {
                    final comparisonData =
                    FinanceCalculator.calculateMonthlyComparison(widget.transactions);
                    double maxVal = 1.0;
                    for (var d in comparisonData) {
                      if (d.income > maxVal) maxVal = d.income;
                      if (d.expense > maxVal) maxVal = d.expense;
                    }
                    return CustomPaint(
                      painter: BarChartPainter(data: comparisonData, maxAmount: maxVal),
                    );
                  })(),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _reportType = ReportType.category),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _reportType == ReportType.category
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: _reportType == ReportType.category
                            ? [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 2)
                        ]
                            : [],
                      ),
                      alignment: Alignment.center,
                      child: Text("By Category",
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: _reportType == ReportType.category
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _reportType = ReportType.accountType),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _reportType == ReportType.accountType
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: _reportType == ReportType.accountType
                            ? [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 2)
                        ]
                            : [],
                      ),
                      alignment: Alignment.center,
                      child: Text("By Account Type",
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: _reportType == ReportType.accountType
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: const Color(0xFF2563EB),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: const Color(0xFF2563EB).withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 5))
                ]),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Total Spending",
                    style: GoogleFonts.inter(
                        color: Colors.white.withOpacity(0.9), fontSize: 16)),
                Text(FinanceCalculator.formatCurrency(monthlyExpense),
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (sortedBreakdown.isNotEmpty) ...[
            Text(
                _reportType == ReportType.category
                    ? 'CATEGORY BREAKDOWN'
                    : 'ACCOUNT TYPE BREAKDOWN',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 1)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(20)),
              child: _isPieChart
                  ? _buildPieChart(sortedBreakdown, monthlyExpense)
                  : _buildBarList(sortedBreakdown, monthlyExpense),
            ),
          ] else
            Center(
                child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text("No expenses for this month",
                        style: GoogleFonts.inter(color: Colors.grey)))),
        ],
      ),
    );
  }

  Widget _buildBarList(Map<String, double> data, double total) {
    return Column(
      children: data.entries.map((entry) {
        final percentage = (entry.value / total);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                  child: Text(entry.key,
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface),
                      overflow: TextOverflow.ellipsis),
                ),
                Text(FinanceCalculator.formatCurrency(entry.value),
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface))
              ]),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                  value: percentage,
                  backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                  color: const Color(0xFF2563EB),
                  borderRadius: BorderRadius.circular(4),
                  minHeight: 6),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPieChart(Map<String, double> data, double total) {
    int colorIdx = 0;
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: CustomPaint(
            painter: PieChartPainter(
              data: data,
              total: total,
              colors: data.keys.map((_) => _getColor(colorIdx++)).toList(),
              surfaceColor: Theme.of(context).colorScheme.surface,
            ),
            size: const Size(200, 200),
          ),
        ),
        const SizedBox(height: 24),
        ...data.entries.toList().asMap().entries.map((e) {
          final idx = e.key;
          final entry = e.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                        color: _getColor(idx), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(entry.key,
                        style: GoogleFonts.inter(fontSize: 14),
                        overflow: TextOverflow.ellipsis)),
                Text(FinanceCalculator.formatCurrency(entry.value),
                    style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class PieChartPainter extends CustomPainter {
  final Map<String, double> data;
  final double total;
  final List<Color> colors;
  final Color surfaceColor;

  PieChartPainter(
      {required this.data,
      required this.total,
      required this.colors,
      required this.surfaceColor});

  @override
  void paint(Canvas canvas, Size size) {
    double startAngle = -pi / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    int i = 0;
    data.forEach((key, value) {
      final sweepAngle = (value / total) * 2 * pi;
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;

      canvas.drawArc(rect, startAngle, sweepAngle, true, paint);

      final borderPaint = Paint()
        ..color = surfaceColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawArc(rect, startAngle, sweepAngle, true, borderPaint);

      startAngle += sweepAngle;
      i++;
    });

    final holePaint = Paint()..color = surfaceColor;
    canvas.drawCircle(center, radius * 0.5, holePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class BarChartPainter extends CustomPainter {
  final List<MonthlyData> data;
  final double maxAmount;

  BarChartPainter({required this.data, required this.maxAmount});

  @override
  void paint(Canvas canvas, Size size) {
    final paintIncome = Paint()..color = Colors.green.shade400;
    final paintExpense = Paint()..color = Colors.red.shade400;
    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);

    double spacing = size.width / data.length;
    double barWidth = (spacing * 0.6) / 2;

    for (int i = 0; i < data.length; i++) {
      double x = i * spacing + spacing / 2;
      
      // Income Bar
      double incomeHeight = maxAmount > 0 ? (data[i].income / maxAmount) * size.height : 0;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x - barWidth, size.height - incomeHeight, barWidth - 2, incomeHeight),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        paintIncome,
      );

      // Expense Bar
      double expenseHeight = maxAmount > 0 ? (data[i].expense / maxAmount) * size.height : 0;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x + 2, size.height - expenseHeight, barWidth - 2, expenseHeight),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        paintExpense,
      );

      // Month Label
      textPainter.text = TextSpan(
        text: data[i].month.split(' ')[0],
        style: GoogleFonts.inter(fontSize: 10, color: Colors.blueGrey.shade400),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, size.height + 8));
    }
  }

  @override
  bool shouldRepaint(covariant BarChartPainter oldDelegate) => true;
}

// --- 7. Categories Tab ---

class CategoriesTab extends StatefulWidget {
  final Map<String, List<String>> categories;

  const CategoriesTab({super.key, required this.categories});

  @override
  State<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends State<CategoriesTab> {
  void _updateCategories(Map<String, List<String>> newCats) {
    final user = AuthService.currentUser;
    if (user != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('settings')
          .doc('categories')
          .set({'data': newCats});
    }
  }

  void _addCategory() {
    TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("New Category"),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: "Category Name"),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
              onPressed: () {
                if (ctrl.text.isNotEmpty) {
                  final newCats =
                  Map<String, List<String>>.from(widget.categories);
                  newCats[ctrl.text] = [];
                  _updateCategories(newCats);
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Add")),
        ],
      ),
    );
  }

  void _addSubCategory(String category) {
    TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Add to $category"),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: "Sub-Category Name"),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
              onPressed: () {
                if (ctrl.text.isNotEmpty) {
                  final newCats =
                  Map<String, List<String>>.from(widget.categories);
                  newCats[category] = List.from(newCats[category]!)
                    ..add(ctrl.text);
                  _updateCategories(newCats);
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Add")),
        ],
      ),
    );
  }

  void _editCategory(String oldName) {
    TextEditingController ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit Category"),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: "Name"),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () {
                showDialog(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text("Delete Category?"),
                      content: const Text(
                          "This will delete the category and all sub-categories options."),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: const Text("Cancel")),
                        TextButton(
                            onPressed: () {
                              final newCats =
                              Map<String, List<String>>.from(
                                  widget.categories);
                              newCats.remove(oldName);
                              _updateCategories(newCats);
                              Navigator.pop(c);
                              Navigator.pop(ctx);
                            },
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red),
                            child: const Text("Delete")),
                      ],
                    ));
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text("Delete")),
          TextButton(
              onPressed: () {
                if (ctrl.text.isNotEmpty && ctrl.text != oldName) {
                  final newCats =
                  Map<String, List<String>>.from(widget.categories);
                  final subs = newCats.remove(oldName);
                  newCats[ctrl.text] = subs!;
                  _updateCategories(newCats);
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Save")),
        ],
      ),
    );
  }

  void _editSubCategory(String category, String oldSub) {
    TextEditingController ctrl = TextEditingController(text: oldSub);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit Sub-Category"),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: "Name"),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () {
                final newCats =
                Map<String, List<String>>.from(widget.categories);
                newCats[category] = List.from(newCats[category]!)
                  ..remove(oldSub);
                _updateCategories(newCats);
                Navigator.pop(ctx);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text("Delete")),
          TextButton(
              onPressed: () {
                if (ctrl.text.isNotEmpty) {
                  final newCats =
                  Map<String, List<String>>.from(widget.categories);
                  final list = List<String>.from(newCats[category]!);
                  final idx = list.indexOf(oldSub);
                  if (idx != -1) list[idx] = ctrl.text;
                  newCats[category] = list;
                  _updateCategories(newCats);
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Save")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sort categories alphabetically
    final sortedCategories = widget.categories.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
          title: Text('Categories',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface))),
      floatingActionButton: FloatingActionButton(
        onPressed: _addCategory,
        backgroundColor: const Color(0xFF2563EB),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: sortedCategories.map((cat) {
          // Sort subcategories alphabetically
          final subs = List<String>.from(widget.categories[cat]!)..sort();
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Theme.of(context).dividerColor)),
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(cat,
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface)),
              trailing: IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  onPressed: () => _editCategory(cat)),
              childrenPadding:
              const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...subs.map((sub) => GestureDetector(
                      onLongPress: () => _editSubCategory(cat, sub),
                      child: Chip(
                        label: Text(sub,
                            style: GoogleFonts.inter(fontSize: 14)),
                        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                        side: BorderSide.none,
                      ),
                    )),
                    ActionChip(
                      label:
                      const Icon(Icons.add, size: 16, color: Colors.blue),
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      side: BorderSide(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
                      onPressed: () => _addSubCategory(cat),
                    )
                  ],
                )
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// --- 8. Transaction Item Widget ---

class TransactionItem extends StatelessWidget {
  final Transaction transaction;
  final List<Account> accounts;

  const TransactionItem(
      {super.key, required this.transaction, required this.accounts});

  void _deleteTransaction(BuildContext context, String id) {
    final user = AuthService.currentUser;
    if (user == null) return;

    final firestore = FirebaseFirestore.instance;
    final userDoc = firestore.collection('users').doc(user.uid);

    final txn = transaction;

    final sourceAccount = accounts.firstWhere(
            (a) => a.id == txn.sourceAccountId,
        orElse: () => Account(
            id: -1,
            name: 'Unknown',
            balance: 0,
            type: AccountType.cash,
            createdDate: DateTime.now()));

    // Revert balances
    if (sourceAccount.id != -1) {
      double newBalance = sourceAccount.balance;
      if (txn.type == TransactionType.expense) {
        newBalance += txn.amount;
      } else if (txn.type == TransactionType.transfer) {
        newBalance += (txn.amount + txn.fee);
      } else if (txn.type == TransactionType.income) {
        newBalance -= txn.amount;
      }
      // Note: EncryptionService handles double -> encrypted string inside the model's toMap().
      // However, for updates, we often need to set specific fields.
      // Since toMap handles encryption, we can create a temporary Account object and use toMap,
      // or manually encrypt here.

      // Let's create a temp object update logic via `userDoc` which is cleaner.
      // But `update` requires a Map.

      userDoc
          .collection('accounts')
          .doc(sourceAccount.id.toString())
          .update({'balance': EncryptionService.encryptDouble(newBalance)});
    }

    if (txn.type == TransactionType.transfer && txn.targetAccountId != null) {
      final targetAccount = accounts.firstWhere(
              (a) => a.id == txn.targetAccountId,
          orElse: () => Account(
              id: -1,
              name: 'Unknown',
              balance: 0,
              type: AccountType.cash,
              createdDate: DateTime.now()));
      if (targetAccount.id != -1) {
        double newBal = targetAccount.balance - txn.amount;
        userDoc
            .collection('accounts')
            .doc(targetAccount.id.toString())
            .update({'balance': EncryptionService.encryptDouble(newBal)});
      }
    }

    userDoc.collection('transactions').doc(id).delete();
  }

  void _showEditSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTransactionSheet(
          accounts: accounts, existingTransaction: transaction),
    );
  }

  void _showTransactionDetails(BuildContext context) {
    const formatCurrency = FinanceCalculator.formatCurrency;

    final accountName = accounts
        .firstWhere((a) => a.id == transaction.sourceAccountId,
        orElse: () => Account(
            id: -1,
            name: 'Unknown',
            balance: 0,
            type: AccountType.cash,
            createdDate: DateTime.now()))
        .name;

    String? targetAccountName;
    if (transaction.targetAccountId != null) {
      targetAccountName = accounts
          .firstWhere((a) => a.id == transaction.targetAccountId,
          orElse: () => Account(
              id: -1,
              name: 'Unknown',
              balance: 0,
              type: AccountType.cash,
              createdDate: DateTime.now()))
          .name;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Transaction Details",
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow(
                  "Type",
                  transaction.type.name[0].toUpperCase() +
                      transaction.type.name.substring(1)),
              _detailRow("Date",
                  DateFormat('dd MMM yyyy, hh:mm a').format(transaction.date)),
              _detailRow(
                  transaction.type == TransactionType.transfer
                      ? "From Account"
                      : "Account",
                  accountName),
              if (targetAccountName != null)
                _detailRow("To Account", targetAccountName),
              _detailRow("Amount", formatCurrency(transaction.amount)),
              if (transaction.fee > 0)
                _detailRow("Fee", formatCurrency(transaction.fee)),
              if (transaction.recurrence != RecurrenceFrequency.none)
                _detailRow(
                    "Recurring",
                    transaction.recurrence.name[0].toUpperCase() +
                        transaction.recurrence.name.substring(1)),
              const Divider(),
              if (transaction.type == TransactionType.expense) ...[
                if (transaction.splits != null &&
                    transaction.splits!.isNotEmpty) ...[
                  Text("Split Breakdown:",
                      style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...transaction.splits!.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                            "${s.category}${s.subCategory != null ? ' - ${s.subCategory}' : ''}",
                            style: GoogleFonts.inter(fontSize: 13)),
                        Text(formatCurrency(s.amount),
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  )),
                ] else ...[
                  _detailRow("Category", transaction.category),
                  if (transaction.subCategory != null)
                    _detailRow("Sub-Category", transaction.subCategory!),
                ],
              ],
              const Divider(),
              if (transaction.note != null && transaction.note!.isNotEmpty)
                _detailRow("Note", transaction.note!),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90, // Slightly increased for "From Account"
            child: Text(label,
                style: GoogleFonts.inter(
                    color: Colors.grey, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w500, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTransfer = transaction.type == TransactionType.transfer;
    final isIncome = transaction.type == TransactionType.income;
    final isSplit =
        transaction.splits != null && transaction.splits!.isNotEmpty;

    Color color =
    isIncome ? Colors.green : (isTransfer ? Colors.blue : Colors.red);
    IconData icon = isIncome
        ? Icons.arrow_upward
        : (isTransfer ? Icons.swap_horiz : Icons.trending_down);
    String amountText = FinanceCalculator.formatCurrency(
        transaction.amount + (isTransfer ? transaction.fee : 0));

    return GestureDetector(
      onTap: () => _showTransactionDetails(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: color.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                          isTransfer
                              ? 'Wallet Transfer'
                              : (isIncome
                              ? 'Income'
                              : (isSplit
                              ? 'Split Expense'
                              : transaction.category)),
                          style:
                          GoogleFonts.inter(fontWeight: FontWeight.w600)),
                      if (transaction.recurrence != RecurrenceFrequency.none)
                        Padding(
                          padding: const EdgeInsets.only(left: 6.0),
                          child:
                          Icon(Icons.repeat, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      Text(DateFormat('dd MMM').format(transaction.date),
                          style: GoogleFonts.inter(
                              fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      if (isTransfer && transaction.targetAccountId != null)
                        Text(
                            '• To: ${accounts.firstWhere((a) => a.id == transaction.targetAccountId, orElse: () => Account(id: -1, name: 'Unknown', balance: 0, type: AccountType.cash, createdDate: DateTime.now())).name}',
                            style: GoogleFonts.inter(
                                fontSize: 11,
                                color: Colors.blueGrey.shade400,
                                fontWeight: FontWeight.bold)),
                      if (transaction.subCategory != null &&
                          !isTransfer &&
                          !isSplit &&
                          !isIncome)
                        Text('• ${transaction.subCategory}',
                            style: GoogleFonts.inter(
                                fontSize: 11, color: Colors.blueGrey.shade400)),
                      if (isSplit)
                        Text('• ${transaction.splits!.length} items',
                            style: GoogleFonts.inter(
                                fontSize: 11, color: Colors.blueGrey.shade400)),
                      if (transaction.fee > 0)
                        Text('• Fee: ${transaction.fee}',
                            style: GoogleFonts.inter(
                                fontSize: 10, color: Colors.red.shade400)),
                    ],
                  ),
                  if (transaction.note != null && transaction.note!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        transaction.note!,
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: Colors.blueGrey.shade400),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            Text('${isIncome ? "+" : "-"}$amountText',
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.bold, color: color)),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
              onSelected: (val) {
                if (val == 'edit') _showEditSheet(context);
                if (val == 'delete')
                  _deleteTransaction(context, transaction.id);
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                    value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit, size: 18),
                      SizedBox(width: 8),
                      Text("Edit")
                    ])),
                const PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete, size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text("Delete", style: TextStyle(color: Colors.red))
                    ])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- 9. Add Account Sheet ---

class AddAccountSheet extends StatefulWidget {
  final Account? existingAccount;

  const AddAccountSheet({super.key, this.existingAccount});

  @override
  State<AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends State<AddAccountSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _balanceCtrl = TextEditingController();
  AccountType _selectedType = AccountType.bank;
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    if (widget.existingAccount != null) {
      _nameCtrl.text = widget.existingAccount!.name;
      // Convert from base INR to current display currency
      final displayBalance = FinanceCalculator.convertFromBase(widget.existingAccount!.balance);
      _balanceCtrl.text = displayBalance.toStringAsFixed(2);
      _selectedType = widget.existingAccount!.type;
      _selectedDate = widget.existingAccount!.createdDate;
    }
  }

  void _save() {
    final user = AuthService.currentUser;
    if (user == null) return;

    final double displayBalance = double.tryParse(_balanceCtrl.text) ?? 0.0;
    // Convert from current display currency back to base INR
    final double balance = FinanceCalculator.convertToBase(displayBalance);
    final int id =
        widget.existingAccount?.id ?? DateTime.now().millisecondsSinceEpoch;

    final account = Account(
        id: id,
        name: _nameCtrl.text,
        balance: balance,
        type: _selectedType,
        createdDate: _selectedDate);

    FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('accounts')
        .doc(id.toString())
        .set(account.toMap());

    Navigator.pop(context);
  }

  void _delete() {
    final user = AuthService.currentUser;
    if (user != null && widget.existingAccount != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('accounts')
          .doc(widget.existingAccount!.id.toString())
          .delete();
    }
    Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate,
        firstDate: DateTime(2020),
        lastDate: DateTime.now());
    if (picked != null) setState(() => _selectedDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.existingAccount != null;

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(24)))),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(isEditing ? 'EDIT ACCOUNT' : 'ADD ACCOUNT',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey.shade800)),
              if (isEditing)
                IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: _delete)
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: AccountType.values.map((type) {
                final isSelected = _selectedType == type;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedType = type),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                          color: isSelected ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: isSelected
                              ? [
                            BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 4)
                          ]
                              : []),
                      alignment: Alignment.center,
                      child: Text(
                          type.name[0].toUpperCase() + type.name.substring(1),
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: isSelected
                                  ? Colors.black
                                  : Colors.grey.shade600)),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
              controller: _nameCtrl,
              style:
              GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                  hintText: 'Account Name',
                  labelText: "Name",
                  border: UnderlineInputBorder())),
          const SizedBox(height: 16),
          TextField(
              controller: _balanceCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))
              ],
              style:
              GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                  prefixText: '${FinanceCalculator.getSelectedCurrencySymbol()} ',
                  border: InputBorder.none,
                  hintText: '0.00 (Optional)')),
          GestureDetector(
            onTap: _pickDate,
            child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: Colors.grey.shade300))),
                child: Row(children: [
                  const Icon(Icons.calendar_today,
                      size: 16, color: Colors.blueGrey),
                  const SizedBox(width: 8),
                  Text('Date: ',
                      style: GoogleFonts.inter(
                          fontSize: 14, color: Colors.grey.shade600)),
                  Text(DateFormat('dd MMM yyyy').format(_selectedDate),
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey.shade800))
                ])),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: () {
                if (_nameCtrl.text.isNotEmpty) _save();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16))),
              child: Text(isEditing ? 'Save Changes' : 'Create Account',
                  style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

// --- 10. Add Transaction Sheet ---

class AddTransactionSheet extends StatefulWidget {
  final List<Account> accounts;
  final Transaction? existingTransaction;

  const AddTransactionSheet(
      {super.key, required this.accounts, this.existingTransaction});

  @override
  State<AddTransactionSheet> createState() => _AddTransactionSheetState();
}

class _AddTransactionSheetState extends State<AddTransactionSheet> {
  TransactionType _selectedType = TransactionType.expense;
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _feeCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();
  late int _selectedSourceId;
  late int _selectedTargetId;
  DateTime _selectedDate = DateTime.now();
  bool _isSplitMode = false;
  final List<TransactionSplit> _currentSplits = [];
  final TextEditingController _splitAmountCtrl = TextEditingController();
  String? _splitErrorText;
  String? _submitErrorText;
  RecurrenceFrequency _recurrence = RecurrenceFrequency.none;

  Map<String, List<String>> _expenseCategories = {};
  final List<String> _incomeCategories = [
    'Salary',
    'Cash',
    'Gift',
    'Refund',
    'Bonus',
    'Other'
  ];
  String _selectedCategory = '';
  String? _selectedSubCategory;

  @override
  void initState() {
    super.initState();
    _incomeCategories.sort(); // Sort income categories
    _fetchCategories();

    _splitAmountCtrl.addListener(_validateSplitAmount);
    _amountCtrl.addListener(_validateSplitAmount);

    if (widget.accounts.isNotEmpty) {
      _selectedSourceId = widget.accounts.first.id;
      _selectedTargetId = widget.accounts.length > 1
          ? widget.accounts[1].id
          : widget.accounts.first.id;
    }

    if (widget.existingTransaction != null) {
      final t = widget.existingTransaction!;
      _selectedType = t.type;
      // Convert from base INR to current display currency
      final displayAmount = FinanceCalculator.convertFromBase(t.amount);
      final displayFee = FinanceCalculator.convertFromBase(t.fee);
      _amountCtrl.text = displayAmount.toStringAsFixed(2);
      _feeCtrl.text = displayFee.toStringAsFixed(2);
      _noteCtrl.text = t.note ?? '';
      _selectedSourceId = t.sourceAccountId;
      if (t.targetAccountId != null) _selectedTargetId = t.targetAccountId!;
      _selectedCategory = t.category;
      _selectedSubCategory = t.subCategory;
      _selectedDate = t.date;
      _recurrence = t.recurrence;
      if (t.splits != null && t.splits!.isNotEmpty) {
        _isSplitMode = true;
        // Also convert splits from base
        _currentSplits.addAll(t.splits!.map((s) => TransactionSplit(
          category: s.category,
          subCategory: s.subCategory,
          amount: FinanceCalculator.convertFromBase(s.amount),
        )));
      }
    }
  }

  void _fetchCategories() async {
    final user = AuthService.currentUser;
    if (user != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('settings')
          .doc('categories')
          .get();
      if (doc.exists && doc.data()!.containsKey('data')) {
        setState(() {
          _expenseCategories = (doc.data()!['data'] as Map).map((k, v) =>
              MapEntry(
                  k.toString(), (v as List).map((e) => e.toString()).toList()));

          if (_selectedCategory.isEmpty && _expenseCategories.isNotEmpty) {
            // Pick first alphabetically
            final sortedKeys = _expenseCategories.keys.toList()..sort();
            _selectedCategory = sortedKeys.first;
            _selectedSubCategory =
                _expenseCategories[_selectedCategory]?.firstOrNull;
          }
        });
      } else {
        // Fallback default
        setState(() {
          _expenseCategories = {
            'Food': ['Groceries', 'Restaurant', 'Snacks'],
            'Bills': ['Rent', 'Electricity', 'Internet', 'Water', 'Phone'],
            'Transport': ['Fuel', 'Taxi', 'Public', 'Repair'],
            'Shopping': ['Clothes', 'Electronics', 'Home', 'Gifts'],
          };
          // Pick first alphabetically
          final sortedKeys = _expenseCategories.keys.toList()..sort();
          _selectedCategory = sortedKeys.first;
          _selectedSubCategory =
              _expenseCategories[_selectedCategory]?.firstOrNull;
        });
      }
    }
  }

  @override
  void dispose() {
    _splitAmountCtrl.removeListener(_validateSplitAmount);
    _amountCtrl.removeListener(_validateSplitAmount);
    _splitAmountCtrl.dispose();
    _amountCtrl.dispose();
    _feeCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _validateSplitAmount() {
    if (!_isSplitMode) return;

    final double totalAmount = double.tryParse(_amountCtrl.text) ?? 0;
    final double splitAmt = double.tryParse(_splitAmountCtrl.text) ?? 0;

    if (totalAmount <= 0) {
      if (splitAmt > 0) {
        setState(() => _splitErrorText = "Enter Total Amount first");
      } else {
        setState(() => _splitErrorText = null);
      }
      return;
    }

    final double currentTotalSplits =
    _currentSplits.fold(0.0, (sum, item) => sum + item.amount);
    final double remaining = totalAmount - currentTotalSplits;

    if (splitAmt > remaining + 0.01) {
      setState(() {
        _splitErrorText = "Max allowed: ${remaining.toStringAsFixed(2)}";
      });
    } else {
      if (_splitErrorText != null) {
        setState(() => _splitErrorText = null);
      }
    }
  }

  void _save() {
    final user = AuthService.currentUser;
    if (user == null) return;
    setState(() => _submitErrorText = null);

    final double displayAmount = double.tryParse(_amountCtrl.text) ?? 0;
    final double displayFee = double.tryParse(_feeCtrl.text) ?? 0;
    if (displayAmount <= 0) return;

    // Convert from current display currency back to base INR
    final double amount = FinanceCalculator.convertToBase(displayAmount);
    final double fee = FinanceCalculator.convertToBase(displayFee);

    if (_selectedType == TransactionType.expense && _isSplitMode) {
      final splitTotal = _currentSplits.fold(0.0, (sum, s) => sum + s.amount);
      if ((splitTotal - displayAmount).abs() > 0.01) {
        setState(() {
          _submitErrorText =
          "Split total (${splitTotal.toStringAsFixed(2)}) != Amount (${displayAmount.toStringAsFixed(2)})";
        });
        return;
      }
    }

    final firestore = FirebaseFirestore.instance;
    final userDoc = firestore.collection('users').doc(user.uid);
    final batch = firestore.batch();

    Map<int, double> tempBalances = {
      for (var a in widget.accounts) a.id: a.balance
    };

    if (widget.existingTransaction != null) {
      final oldTxn = widget.existingTransaction!;

      if (tempBalances.containsKey(oldTxn.sourceAccountId)) {
        double current = tempBalances[oldTxn.sourceAccountId]!;
        if (oldTxn.type == TransactionType.expense) {
          current += oldTxn.amount;
        } else if (oldTxn.type == TransactionType.transfer) {
          current += (oldTxn.amount + oldTxn.fee);
        } else if (oldTxn.type == TransactionType.income) {
          current -= oldTxn.amount;
        }
        tempBalances[oldTxn.sourceAccountId] = current;
      }

      if (oldTxn.type == TransactionType.transfer &&
          oldTxn.targetAccountId != null &&
          tempBalances.containsKey(oldTxn.targetAccountId)) {
        double current = tempBalances[oldTxn.targetAccountId!]!;
        current -= oldTxn.amount;
        tempBalances[oldTxn.targetAccountId!] = current;
      }
    }

    if (tempBalances.containsKey(_selectedSourceId)) {
      double current = tempBalances[_selectedSourceId]!;
      if (_selectedType == TransactionType.expense) {
        current -= amount;
      } else if (_selectedType == TransactionType.transfer) {
        current -= (amount + fee);
      } else if (_selectedType == TransactionType.income) {
        current += amount;
      }
      tempBalances[_selectedSourceId] = current;
    }

    if (_selectedType == TransactionType.transfer &&
        tempBalances.containsKey(_selectedTargetId)) {
      double current = tempBalances[_selectedTargetId]!;
      current += amount;
      tempBalances[_selectedTargetId] = current;
    }

    tempBalances.forEach((id, newBalance) {
      final accRef = userDoc.collection('accounts').doc(id.toString());
      batch.update(accRef, {'balance': EncryptionService.encryptDouble(newBalance)});
    });

    final newTxn = Transaction(
      id: widget.existingTransaction?.id ?? DateTime.now().toString(),
      amount: amount,
      fee: fee,
      type: _selectedType,
      sourceAccountId: _selectedSourceId,
      targetAccountId:
      _selectedType == TransactionType.transfer ? _selectedTargetId : null,
      category: _selectedType == TransactionType.expense
          ? (_isSplitMode ? 'Split' : _selectedCategory)
          : (_selectedType == TransactionType.income
          ? _selectedCategory
          : 'Transfer'),
      subCategory: _selectedType == TransactionType.expense
          ? (_isSplitMode ? null : _selectedSubCategory)
          : null,
      date: _selectedDate,
      splits: _isSplitMode
          ? _currentSplits.map((s) => TransactionSplit(
        category: s.category,
        subCategory: s.subCategory,
        amount: FinanceCalculator.convertToBase(s.amount),
      )).toList()
          : null,
      note: _noteCtrl.text.isEmpty ? null : _noteCtrl.text,
      recurrence: _recurrence,
    );

    final txnRef = userDoc.collection('transactions').doc(newTxn.id);
    batch.set(txnRef, newTxn.toMap());

    batch.commit();
    Navigator.pop(context);
  }

  void _ensureValidTarget() {
    if (_selectedType == TransactionType.transfer) {
      if (_selectedSourceId == _selectedTargetId) {
        final available =
        widget.accounts.where((a) => a.id != _selectedSourceId);
        if (available.isNotEmpty) _selectedTargetId = available.first.id;
      }
    }
  }

  void _addSplit() {
    final amt = double.tryParse(_splitAmountCtrl.text) ?? 0;
    final totalAmount = double.tryParse(_amountCtrl.text) ?? 0;

    if (totalAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please enter the total amount first")));
      return;
    }

    if (amt <= 0) return;

    if (_splitErrorText != null) {
      return;
    }

    final currentTotal =
    _currentSplits.fold(0.0, (sum, item) => sum + item.amount);
    if ((currentTotal + amt) > totalAmount + 0.01) {
      setState(() {
        _splitErrorText =
        "Exceeds total! Rem: ${FinanceCalculator.getSelectedCurrencySymbol()}${(totalAmount - currentTotal).toStringAsFixed(2)}";
      });
      return;
    }

    setState(() {
      _currentSplits.add(TransactionSplit(
          amount: amt,
          category: _selectedCategory,
          subCategory: _selectedSubCategory));
      _splitAmountCtrl.clear();
      _splitErrorText = null;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate,
        firstDate: DateTime(2020),
        lastDate: DateTime.now());
    if (picked != null) setState(() => _selectedDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final double totalAmount = double.tryParse(_amountCtrl.text) ?? 0;
    final double currentSplitTotal =
    _currentSplits.fold(0, (sum, item) => sum + item.amount);
    final double remaining = totalAmount - currentSplitTotal;

    // Sort accounts for dropdown
    final sortedAccounts = List<Account>.from(widget.accounts)
      ..sort((a, b) => a.name.compareTo(b.name));

    // Sort categories for display
    final sortedExpenseCategories = _expenseCategories.keys.toList()..sort();

    // Sort subcategories if category selected
    List<String> sortedSubCategories = [];
    if (_selectedCategory.isNotEmpty && _expenseCategories[_selectedCategory] != null) {
      sortedSubCategories = List<String>.from(_expenseCategories[_selectedCategory]!)..sort();
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32))),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: TransactionType.values.map((type) {
                  final isSelected = _selectedType == type;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _selectedType = type;
                        _ensureValidTarget();
                        if (_selectedType == TransactionType.income) {
                          _selectedCategory = 'Salary';
                          _selectedSubCategory = null;
                        } else if (_selectedType == TransactionType.expense) {
                          if (_expenseCategories.isNotEmpty) {
                            _selectedCategory = _expenseCategories.keys.first;
                            _selectedSubCategory =
                                _expenseCategories[_selectedCategory]
                                    ?.firstOrNull;
                          }
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                            color:
                            isSelected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: isSelected
                                ? [
                              BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 4)
                            ]
                                : []),
                        alignment: Alignment.center,
                        child: Text(
                            type.name[0].toUpperCase() + type.name.substring(1),
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                    : Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _pickDate,
              child: Container(
                  padding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                   decoration: BoxDecoration(
                       border: Border.all(color: Theme.of(context).dividerColor),
                       borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.calendar_today,
                        size: 18, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(DateFormat('dd MMM yyyy').format(_selectedDate),
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface)),
                    const Spacer(),
                    Text('Change',
                        style: GoogleFonts.inter(
                            color: const Color(0xFF2563EB),
                            fontWeight: FontWeight.bold,
                            fontSize: 12))
                  ])),
            ),
            const SizedBox(height: 16),
            TextField(
                controller: _amountCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))
                ],
                onChanged: (val) => setState(() {}),
                style: GoogleFonts.inter(
                    fontSize: 24, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                    labelText: "AMOUNT",
                    prefixText: '${FinanceCalculator.getSelectedCurrencySymbol()} ',
                    border: InputBorder.none)),
            const Divider(),
            const SizedBox(height: 16),
            Text(
                _selectedType == TransactionType.income ? 'DEPOSIT TO' : 'FROM',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            DropdownButton<int>(
                value: _selectedSourceId,
                isExpanded: true,
                underline: const SizedBox(),
                items: sortedAccounts
                    .map((a) =>
                    DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (val) => setState(() {
                  _selectedSourceId = val!;
                  _ensureValidTarget();
                })),
            if (_selectedType == TransactionType.transfer) ...[
              const SizedBox(height: 16),
              Text('TO',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade400)),
              DropdownButton<int>(
                  value: _selectedTargetId,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: sortedAccounts
                      .where((a) => a.id != _selectedSourceId)
                      .map((a) =>
                      DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (val) => setState(() => _selectedTargetId = val!)),
              const SizedBox(height: 16),
              TextField(
                  controller: _feeCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))
                  ],
                  decoration: InputDecoration(
                      labelText: "FEE",
                      prefixText: '${FinanceCalculator.getSelectedCurrencySymbol()} ',
                      border: InputBorder.none)),
            ],
            if (_selectedType == TransactionType.income) ...[
              const SizedBox(height: 16),
              Text('CATEGORY',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade400)),
              const SizedBox(height: 8),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _incomeCategories // Already sorted in initState
                      .map((c) => ChoiceChip(
                      label: Text(c),
                      selected: _selectedCategory == c,
                      onSelected: (val) =>
                          setState(() => _selectedCategory = c),
                      selectedColor: Theme.of(context).colorScheme.primaryContainer,
                      labelStyle: TextStyle(
                          color: _selectedCategory == c 
                              ? Theme.of(context).colorScheme.onPrimaryContainer 
                              : Theme.of(context).colorScheme.onSurface)))
                      .toList()),
            ],
            if (_selectedType == TransactionType.expense) ...[
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('CATEGORY',
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade400)),
                Row(children: [
                  Text('Split?',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: _isSplitMode ? Colors.blue : Colors.grey)),
                  Switch(
                      value: _isSplitMode,
                      onChanged: (val) => setState(() => _isSplitMode = val),
                      activeColor: const Color(0xFF2563EB))
                ])
              ]),
              if (_isSplitMode) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200)),
                  child: Column(
                    children: [
                      ..._currentSplits.asMap().entries.map((entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Row(children: [
                            Expanded(
                                child: Text(
                                    '${entry.value.category} > ${entry.value.subCategory}',
                                    style: GoogleFonts.inter(fontSize: 13))),
                            Text('${FinanceCalculator.getSelectedCurrencySymbol()}${entry.value.amount.toInt()}',
                                style: GoogleFonts.inter(
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                onPressed: () => setState(() {
                                  _currentSplits.removeAt(entry.key);
                                  _validateSplitAmount();
                                }),
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.red))
                          ]))),
                      const Divider(),
                      if (remaining > 0.01) ...[
                        Row(children: [
                          Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                  value: _selectedCategory,
                                  isExpanded: true,
                                  underline: const SizedBox(),
                                  items: sortedExpenseCategories
                                      .map((c) => DropdownMenuItem(
                                      value: c, child: Text(c)))
                                      .toList(),
                                  onChanged: (val) => setState(() {
                                    _selectedCategory = val!;
                                    final subs = _expenseCategories[val];
                                    if (subs != null && subs.isNotEmpty) {
                                      final sortedSubs = List<String>.from(subs)..sort();
                                      _selectedSubCategory = sortedSubs.first;
                                    } else {
                                      _selectedSubCategory = null;
                                    }
                                  }))),
                          const SizedBox(width: 8),
                          Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                  value: _selectedSubCategory,
                                  isExpanded: true,
                                  underline: const SizedBox(),
                                  items: sortedSubCategories
                                      .map((s) => DropdownMenuItem(
                                      value: s, child: Text(s)))
                                      .toList(),
                                  onChanged: (val) => setState(
                                          () => _selectedSubCategory = val)))
                        ]),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: _splitAmountCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(
                                        RegExp(r'^\d*\.?\d*'))
                                  ],
                                  decoration: InputDecoration(
                                      hintText:
                                      'Remaining: ${remaining.toStringAsFixed(2)}',
                                      errorText: _splitErrorText,
                                      isDense: true))),
                          TextButton(
                              onPressed: _addSplit, child: const Text('Add'))
                        ]),
                      ] else
                        Text("Total matched!",
                            style: GoogleFonts.inter(
                                color: Colors.green,
                                fontWeight: FontWeight.bold)),
                    ],
                  ),
                )
              ] else ...[
                const SizedBox(height: 8),
                SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                        children: sortedExpenseCategories
                            .map((c) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                                label: Text(c),
                                selected: _selectedCategory == c,
                                onSelected: (val) => setState(() {
                                  _selectedCategory = c;
                                  final subs = _expenseCategories[c];
                                  if (subs != null && subs.isNotEmpty) {
                                    final sortedSubs = List<String>.from(subs)..sort();
                                    _selectedSubCategory = sortedSubs.first;
                                  } else {
                                    _selectedSubCategory = null;
                                  }
                                }),
                                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                                labelStyle: TextStyle(
                                    color: _selectedCategory == c 
                                        ? Theme.of(context).colorScheme.onPrimaryContainer 
                                        : Theme.of(context).colorScheme.onSurface))))
                            .toList())),
                if (_selectedSubCategory != null &&
                    _expenseCategories[_selectedCategory] != null) ...[
                  const SizedBox(height: 12),
                  Text('SUB CATEGORY',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade400)),
                  const SizedBox(height: 8),
                  Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: sortedSubCategories // Use sorted list
                          .map((sub) => ChoiceChip(
                          label: Text(sub),
                          selected: _selectedSubCategory == sub,
                          onSelected: (val) =>
                              setState(() => _selectedSubCategory = sub),
                          selectedColor: Theme.of(context).colorScheme.primaryContainer,
                          labelStyle: TextStyle(
                              color: _selectedSubCategory == sub 
                                  ? Theme.of(context).colorScheme.onPrimaryContainer 
                                  : Theme.of(context).colorScheme.onSurface)))
                          .toList())
                ],
              ],
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(
                labelText: "NOTE (OPTIONAL)",
                border: InputBorder.none,
                prefixIcon: Icon(Icons.note_alt_outlined, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RecurrenceFrequency>(
              value: _recurrence,
              decoration: const InputDecoration(
                labelText: "REPEAT",
                border: InputBorder.none,
                prefixIcon: Icon(Icons.repeat, color: Colors.grey),
              ),
              items: RecurrenceFrequency.values.map((freq) {
                String label;
                switch (freq) {
                  case RecurrenceFrequency.none:
                    label = "Never";
                    break;
                  case RecurrenceFrequency.daily:
                    label = "Daily";
                    break;
                  case RecurrenceFrequency.weekly:
                    label = "Weekly";
                    break;
                  case RecurrenceFrequency.monthly:
                    label = "Monthly";
                    break;
                  case RecurrenceFrequency.yearly:
                    label = "Yearly";
                    break;
                }
                return DropdownMenuItem(value: freq, child: Text(label));
              }).toList(),
              onChanged: (val) => setState(() => _recurrence = val!),
            ),
            if (_submitErrorText != null) ...[
              const SizedBox(height: 16),
              Center(
                  child: Text(_submitErrorText!,
                      style: GoogleFonts.inter(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 12))),
            ],
            const SizedBox(height: 32),
            SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16))),
                    child: Text(
                        widget.existingTransaction != null
                            ? 'Save Changes'
                            : 'Save Record',
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)))),
          ],
        ),
      ),
    );
  }
}

// --- TYPE ADAPTERS (Kept for Migration) ---

class AccountTypeAdapter extends TypeAdapter<AccountType> {
  @override
  final int typeId = 3;
  @override
  AccountType read(BinaryReader reader) =>
      AccountType.values[reader.readByte()];
  @override
  void write(BinaryWriter writer, AccountType obj) =>
      writer.writeByte(obj.index);
}

class TransactionTypeAdapter extends TypeAdapter<TransactionType> {
  @override
  final int typeId = 4;
  @override
  TransactionType read(BinaryReader reader) =>
      TransactionType.values[reader.readByte()];
  @override
  void write(BinaryWriter writer, TransactionType obj) =>
      writer.writeByte(obj.index);
}

class TransactionSplitAdapter extends TypeAdapter<TransactionSplit> {
  @override
  final int typeId = 2;
  @override
  TransactionSplit read(BinaryReader reader) => TransactionSplit(
      amount: reader.readDouble(),
      category: reader.readString(),
      subCategory: reader.readBool() ? reader.readString() : null);
  @override
  void write(BinaryWriter writer, TransactionSplit obj) {
    writer.writeDouble(obj.amount);
    writer.writeString(obj.category);
    writer.writeBool(obj.subCategory != null);
    if (obj.subCategory != null) writer.writeString(obj.subCategory!);
  }
}

class AccountAdapter extends TypeAdapter<Account> {
  @override
  final int typeId = 0;
  @override
  Account read(BinaryReader reader) => Account(
      id: reader.readInt(),
      name: reader.readString(),
      balance: reader.readDouble(),
      type: AccountType.values[reader.readByte()],
      createdDate: DateTime.fromMillisecondsSinceEpoch(reader.readInt()));
  @override
  void write(BinaryWriter writer, Account obj) {
    writer.writeInt(obj.id);
    writer.writeString(obj.name);
    writer.writeDouble(obj.balance);
    writer.writeByte(obj.type.index);
    writer.writeInt(obj.createdDate.millisecondsSinceEpoch);
  }
}

class TransactionAdapter extends TypeAdapter<Transaction> {
  @override
  final int typeId = 1;
  @override
  Transaction read(BinaryReader reader) {
    final id = reader.readString();
    final amount = reader.readDouble();
    final fee = reader.readDouble();
    final type = TransactionType.values[reader.readByte()];
    final sourceAccountId = reader.readInt();
    final targetAccountId = reader.readBool() ? reader.readInt() : null;
    final category = reader.readString();
    final subCategory = reader.readBool() ? reader.readString() : null;
    final date = DateTime.fromMillisecondsSinceEpoch(reader.readInt());
    final splits = reader.readBool()
        ? (reader.readList().cast<TransactionSplit>().toList())
        : null;

    String? note;
    if (reader.availableBytes > 0) {
      if (reader.readBool()) {
        note = reader.readString();
      }
    }

    return Transaction(
      id: id,
      amount: amount,
      fee: fee,
      type: type,
      sourceAccountId: sourceAccountId,
      targetAccountId: targetAccountId,
      category: category,
      subCategory: subCategory,
      date: date,
      splits: splits,
      note: note,
      recurrence: RecurrenceFrequency.none, // Default
    );
  }

  @override
  void write(BinaryWriter writer, Transaction obj) {
    writer.writeString(obj.id);
    writer.writeDouble(obj.amount);
    writer.writeDouble(obj.fee);
    writer.writeByte(obj.type.index);
    writer.writeInt(obj.sourceAccountId);
    writer.writeBool(obj.targetAccountId != null);
    if (obj.targetAccountId != null) writer.writeInt(obj.targetAccountId!);
    writer.writeString(obj.category);
    writer.writeBool(obj.subCategory != null);
    if (obj.subCategory != null) writer.writeString(obj.subCategory!);
    writer.writeInt(obj.date.millisecondsSinceEpoch);
    writer.writeBool(obj.splits != null);
    if (obj.splits != null) writer.writeList(obj.splits!);

    writer.writeBool(obj.note != null);
    if (obj.note != null) writer.writeString(obj.note!);
  }
}