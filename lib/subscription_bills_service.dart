import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:intl/intl.dart';
import 'main.dart'
    show
        Account,
        Transaction,
        TransactionType,
        RecurrenceFrequency,
        AuthService,
        EncryptionService;

enum BillStatus {
  upcoming,
  dueToday,
  overdue,
  paid,
}

class BillSubscription {
  final String id;
  final String name;
  final double amount;
  final RecurrenceFrequency frequency;
  final DateTime dueDate;
  final String category;
  final String? defaultAccountId;
  final bool isAutoDebit;
  final DateTime? lastPaidDate;
  final String? note;

  BillSubscription({
    required this.id,
    required this.name,
    required this.amount,
    this.frequency = RecurrenceFrequency.monthly,
    required this.dueDate,
    this.category = 'Bills',
    this.defaultAccountId,
    this.isAutoDebit = false,
    this.lastPaidDate,
    this.note,
  });

  bool isPaidForCurrentCycle([DateTime? now]) {
    if (lastPaidDate == null) return false;
    final current = now ?? DateTime.now();

    switch (frequency) {
      case RecurrenceFrequency.daily:
        return lastPaidDate!.year == current.year &&
            lastPaidDate!.month == current.month &&
            lastPaidDate!.day == current.day;
      case RecurrenceFrequency.weekly:
        return current.difference(lastPaidDate!).inDays < 7 &&
            lastPaidDate!.isAfter(dueDate.subtract(const Duration(days: 7)));
      case RecurrenceFrequency.monthly:
        return lastPaidDate!.year == current.year &&
            lastPaidDate!.month == current.month;
      case RecurrenceFrequency.yearly:
        return lastPaidDate!.year == current.year;
      case RecurrenceFrequency.none:
        return lastPaidDate != null;
    }
  }

  BillStatus getStatus([DateTime? now]) {
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final due = DateTime(dueDate.year, dueDate.month, dueDate.day);

    if (isPaidForCurrentCycle(current)) {
      return BillStatus.paid;
    }
    if (due.isBefore(today)) {
      return BillStatus.overdue;
    }
    if (due.isAtSameMomentAs(today)) {
      return BillStatus.dueToday;
    }
    return BillStatus.upcoming;
  }

  int get daysUntilDue => getDaysUntilDue();

  int getDaysUntilDue([DateTime? now]) {
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final due = DateTime(dueDate.year, dueDate.month, dueDate.day);
    return due.difference(today).inDays;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'amount': amount,
      'frequency': frequency.name,
      'dueDate': dueDate.toIso8601String(),
      'category': category,
      'defaultAccountId': defaultAccountId,
      'isAutoDebit': isAutoDebit,
      'lastPaidDate': lastPaidDate?.toIso8601String(),
      'note': note,
    };
  }

  factory BillSubscription.fromMap(Map<dynamic, dynamic> map) {
    return BillSubscription(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      frequency: RecurrenceFrequency.values.firstWhere(
        (f) => f.name == map['frequency'],
        orElse: () => RecurrenceFrequency.monthly,
      ),
      dueDate: map['dueDate'] != null
          ? DateTime.tryParse(map['dueDate'].toString()) ?? DateTime.now()
          : DateTime.now(),
      category: map['category']?.toString() ?? 'Bills',
      defaultAccountId: map['defaultAccountId']?.toString(),
      isAutoDebit: map['isAutoDebit'] == true,
      lastPaidDate: map['lastPaidDate'] != null
          ? DateTime.tryParse(map['lastPaidDate'].toString())
          : null,
      note: map['note']?.toString(),
    );
  }

  BillSubscription copyWith({
    String? id,
    String? name,
    double? amount,
    RecurrenceFrequency? frequency,
    DateTime? dueDate,
    String? category,
    String? defaultAccountId,
    bool? isAutoDebit,
    DateTime? lastPaidDate,
    String? note,
  }) {
    return BillSubscription(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      frequency: frequency ?? this.frequency,
      dueDate: dueDate ?? this.dueDate,
      category: category ?? this.category,
      defaultAccountId: defaultAccountId ?? this.defaultAccountId,
      isAutoDebit: isAutoDebit ?? this.isAutoDebit,
      lastPaidDate: lastPaidDate ?? this.lastPaidDate,
      note: note ?? this.note,
    );
  }
}

class SubscriptionBillsService {
  static Box? _box;
  static final ValueNotifier<List<BillSubscription>> billsNotifier =
      ValueNotifier<List<BillSubscription>>([]);

  static Future<void> initialize() async {
    _box = await Hive.openBox('bills_subscriptions');
    _loadFromHive();
    final user = AuthService.currentUser;
    if (user != null) {
      syncFromFirestore(user.uid);
    }
  }

  static void _loadFromHive() {
    if (_box == null) return;
    final list = <BillSubscription>[];
    for (var key in _box!.keys) {
      final val = _box!.get(key);
      if (val is Map) {
        list.add(BillSubscription.fromMap(val));
      }
    }
    list.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    billsNotifier.value = list;
  }

  static Future<void> addOrUpdateBill(BillSubscription bill) async {
    if (_box == null) _box = await Hive.openBox('bills_subscriptions');
    await _box!.put(bill.id, bill.toMap());
    _loadFromHive();

    final user = AuthService.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('subscriptions')
            .doc(bill.id)
            .set(bill.toMap());
      } catch (e) {
        debugPrint("Error syncing bill to Firestore: $e");
      }
    }
  }

  static Future<void> deleteBill(String id) async {
    if (_box != null) {
      await _box!.delete(id);
      _loadFromHive();
    }
    final user = AuthService.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('subscriptions')
            .doc(id)
            .delete();
      } catch (e) {
        debugPrint("Error deleting subscription in Firestore: $e");
      }
    }
  }

  static Future<void> syncFromFirestore(String userId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('subscriptions')
          .get();

      if (snapshot.docs.isNotEmpty && _box != null) {
        for (var doc in snapshot.docs) {
          final data = doc.data();
          await _box!.put(doc.id, data);
        }
        _loadFromHive();
      }
    } catch (e) {
      debugPrint("Error syncing subscriptions from Firestore: $e");
    }
  }

  static double calculateTotalMonthlyCommitment(List<BillSubscription> bills) {
    double total = 0.0;
    for (var b in bills) {
      switch (b.frequency) {
        case RecurrenceFrequency.monthly:
          total += b.amount;
          break;
        case RecurrenceFrequency.yearly:
          total += (b.amount / 12);
          break;
        case RecurrenceFrequency.weekly:
          total += (b.amount * 4.33);
          break;
        case RecurrenceFrequency.daily:
          total += (b.amount * 30);
          break;
        case RecurrenceFrequency.none:
          total += b.amount;
          break;
      }
    }
    return total;
  }

  static DateTime calculateNextCycleDueDate(BillSubscription bill) {
    final cur = bill.dueDate;
    switch (bill.frequency) {
      case RecurrenceFrequency.daily:
        return cur.add(const Duration(days: 1));
      case RecurrenceFrequency.weekly:
        return cur.add(const Duration(days: 7));
      case RecurrenceFrequency.monthly:
        int newMonth = cur.month + 1;
        int newYear = cur.year;
        if (newMonth > 12) {
          newMonth = 1;
          newYear++;
        }
        int maxDay = DateTime(newYear, newMonth + 1, 0).day;
        int targetDay = min(cur.day, maxDay);
        return DateTime(newYear, newMonth, targetDay);
      case RecurrenceFrequency.yearly:
        return DateTime(cur.year + 1, cur.month, cur.day);
      case RecurrenceFrequency.none:
        return cur;
    }
  }

  static Future<void> markBillAsPaid({
    required BillSubscription bill,
    required Account sourceAccount,
    required BuildContext context,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) return;

    try {
      final firestore = FirebaseFirestore.instance;
      final userDoc = firestore.collection('users').doc(user.uid);
      final batch = firestore.batch();

      // 1. Record expense transaction
      final txnId = DateTime.now().millisecondsSinceEpoch.toString() +
          Random().nextInt(1000).toString();

      final newTxn = Transaction(
        id: txnId,
        amount: bill.amount,
        type: TransactionType.expense,
        sourceAccountId: sourceAccount.id,
        category: bill.category,
        date: DateTime.now(),
        note: "${bill.name} (Subscription / Bill)",
      );

      final txnRef = userDoc.collection('transactions').doc(newTxn.id);
      batch.set(txnRef, newTxn.toMap());

      // 2. Deduct Account Balance
      final double newBalance = sourceAccount.balance - bill.amount;
      final accRef = userDoc.collection('accounts').doc(sourceAccount.id.toString());
      batch.update(accRef, {
        'balance': EncryptionService.encryptDouble(newBalance),
      });

      // 3. Update Bill status: advance next dueDate and record lastPaidDate
      final nextDue = calculateNextCycleDueDate(bill);
      final updatedBill = bill.copyWith(
        lastPaidDate: DateTime.now(),
        dueDate: nextDue,
      );

      final billRef = userDoc.collection('subscriptions').doc(bill.id);
      batch.set(billRef, updatedBill.toMap());

      await batch.commit();

      // Save updated bill to local Hive
      if (_box != null) {
        await _box!.put(updatedBill.id, updatedBill.toMap());
        _loadFromHive();
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Marked ${bill.name} as paid (₹${bill.amount.toStringAsFixed(0)})!"),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error marking bill paid: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error marking bill paid: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// --- UI Components ---

class UpcomingBillsDashboardCard extends StatelessWidget {
  final List<Account> accounts;
  final VoidCallback onViewAllTap;

  const UpcomingBillsDashboardCard({
    super.key,
    required this.accounts,
    required this.onViewAllTap,
  });

  void _showQuickPaySheet(BuildContext context, BillSubscription bill) {
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please add an account first")),
      );
      return;
    }

    Account selectedAccount = accounts.firstWhere(
      (a) => a.id.toString() == bill.defaultAccountId,
      orElse: () => accounts.first,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final isDark = theme.brightness == Brightness.dark;

          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_circle_outline,
                          color: Color(0xFF10B981), size: 24),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Pay ${bill.name}",
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          "Amount: ₹${NumberFormat('#,##,###').format(bill.amount)}",
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: const Color(0xFF10B981),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  "Pay From Account",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Account>(
                  value: selectedAccount,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  items: accounts
                      .map((a) => DropdownMenuItem(
                            value: a,
                            child: Text(
                              "${a.name} (₹${NumberFormat('#,##,###').format(a.balance)})",
                              style: GoogleFonts.inter(fontSize: 14),
                            ),
                          ))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setSheetState(() => selectedAccount = val);
                    }
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await SubscriptionBillsService.markBillAsPaid(
                        bill: bill,
                        sourceAccount: selectedAccount,
                        context: context,
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      "Confirm & Record Expense",
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ValueListenableBuilder<List<BillSubscription>>(
      valueListenable: SubscriptionBillsService.billsNotifier,
      builder: (context, bills, _) {
        if (bills.isEmpty) {
          return _buildEmptyBillsCard(context, theme, isDark);
        }

        final now = DateTime.now();
        // Filter bills due within next 14 days or overdue
        final upcomingOrOverdue = bills.where((b) {
          final s = b.getStatus(now);
          return s == BillStatus.overdue ||
              s == BillStatus.dueToday ||
              (s == BillStatus.upcoming && b.daysUntilDue <= 14);
        }).toList();

        final totalMonthly =
            SubscriptionBillsService.calculateTotalMonthlyCommitment(bills);

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.grey.shade200,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.25 : 0.04),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B5CF6).withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.event_repeat,
                            color: Color(0xFF8B5CF6), size: 20),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Upcoming Bills",
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            "₹${NumberFormat('#,##,###').format(totalMonthly.round())}/mo committed",
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: Colors.blueGrey.shade400,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: onViewAllTap,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text("View All"),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      textStyle: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (upcomingOrOverdue.isEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle,
                          color: Color(0xFF10B981), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "All clear! No bills due in the next 14 days.",
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...upcomingOrOverdue.take(3).map((b) => _buildBillItemRow(
                    context, b, theme, isDark, now)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyBillsCard(
      BuildContext context, ThemeData theme, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade200,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.event_repeat,
                    color: Color(0xFF8B5CF6), size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                "Subscriptions & Bills",
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            "Track Netflix, Rent, Broadband, and recurring commitments. Get reminders before due dates and log with 1-tap.",
            style: GoogleFonts.inter(
              fontSize: 13,
              color: Colors.blueGrey.shade400,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onViewAllTap,
              icon: const Icon(Icons.add, size: 18),
              label: const Text("Track Subscriptions & Bills"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBillItemRow(
    BuildContext context,
    BillSubscription bill,
    ThemeData theme,
    bool isDark,
    DateTime now,
  ) {
    final status = bill.getStatus(now);
    Color statusColor;
    String statusText;

    switch (status) {
      case BillStatus.overdue:
        statusColor = const Color(0xFFEF4444);
        statusText = "Overdue (${bill.daysUntilDue.abs()}d ago)";
        break;
      case BillStatus.dueToday:
        statusColor = const Color(0xFFF59E0B);
        statusText = "Due Today!";
        break;
      case BillStatus.upcoming:
        statusColor = const Color(0xFF2563EB);
        statusText = "Due in ${bill.daysUntilDue} days";
        break;
      case BillStatus.paid:
        statusColor = const Color(0xFF10B981);
        statusText = "Paid";
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.04) : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.receipt_outlined, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bill.name,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                "₹${NumberFormat('#,##,###').format(bill.amount)}",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () => _showQuickPaySheet(context, bill),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "Pay",
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SubscriptionsBillsScreen extends StatefulWidget {
  final List<Account> accounts;

  const SubscriptionsBillsScreen({super.key, required this.accounts});

  @override
  State<SubscriptionsBillsScreen> createState() =>
      _SubscriptionsBillsScreenState();
}

class _SubscriptionsBillsScreenState extends State<SubscriptionsBillsScreen> {
  int _selectedFilter = 0; // 0: All, 1: Upcoming, 2: Paid

  void _showAddEditBillSheet([BillSubscription? existing]) {
    final isEditing = existing != null;
    final nameController =
        TextEditingController(text: existing != null ? existing.name : '');
    final amountController = TextEditingController(
        text: existing != null ? existing.amount.toStringAsFixed(0) : '');
    RecurrenceFrequency frequency =
        existing?.frequency ?? RecurrenceFrequency.monthly;
    DateTime dueDate = existing?.dueDate ?? DateTime.now().add(const Duration(days: 7));
    String category = existing?.category ?? 'Bills';
    bool isAutoDebit = existing?.isAutoDebit ?? false;

    final presets = [
      {'name': 'Netflix', 'amount': 649, 'category': 'Entmt'},
      {'name': 'Spotify', 'amount': 119, 'category': 'Entmt'},
      {'name': 'YouTube Premium', 'amount': 149, 'category': 'Entmt'},
      {'name': 'Amazon Prime', 'amount': 1499, 'category': 'Shopping'},
      {'name': 'WiFi Broadband', 'amount': 999, 'category': 'Bills'},
      {'name': 'House Rent', 'amount': 18000, 'category': 'Bills'},
      {'name': 'Electricity Bill', 'amount': 2500, 'category': 'Bills'},
      {'name': 'Gym Membership', 'amount': 1500, 'category': 'Health'},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final isDark = theme.brightness == Brightness.dark;

          return Container(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
            ),
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
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isEditing ? "Edit Subscription" : "Add Subscription / Bill",
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!isEditing) ...[
                    Text("Quick Presets",
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: presets.map((p) {
                        return ActionChip(
                          label: Text("${p['name']} (₹${p['amount']})",
                              style: GoogleFonts.inter(fontSize: 12)),
                          onPressed: () {
                            setSheetState(() {
                              nameController.text = p['name'].toString();
                              amountController.text = p['amount'].toString();
                              category = p['category'].toString();
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: "Service or Bill Name",
                      hintText: "e.g. Netflix, Gym, Rent",
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: "Amount (₹)",
                      prefixIcon: const Icon(Icons.currency_rupee, size: 20),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<RecurrenceFrequency>(
                          value: frequency,
                          decoration: InputDecoration(
                            labelText: "Frequency",
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: RecurrenceFrequency.monthly,
                                child: Text("Monthly")),
                            DropdownMenuItem(
                                value: RecurrenceFrequency.yearly,
                                child: Text("Yearly")),
                            DropdownMenuItem(
                                value: RecurrenceFrequency.weekly,
                                child: Text("Weekly")),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setSheetState(() => frequency = val);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: dueDate,
                              firstDate:
                                  DateTime.now().subtract(const Duration(days: 30)),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              setSheetState(() => dueDate = picked);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: "Next Due Date",
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            child: Text(
                              DateFormat('dd MMM yyyy').format(dueDate),
                              style: GoogleFonts.inter(fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: Text("Auto-Debited",
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text("Bank/Card automatically debits this payment",
                        style: GoogleFonts.inter(
                            fontSize: 12, color: Colors.blueGrey.shade400)),
                    value: isAutoDebit,
                    onChanged: (val) => setSheetState(() => isAutoDebit = val),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () async {
                        final name = nameController.text.trim();
                        final amount =
                            double.tryParse(amountController.text.trim());

                        if (name.isEmpty || amount == null || amount <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Please enter a valid name and amount")),
                          );
                          return;
                        }

                        final bill = BillSubscription(
                          id: existing?.id ??
                              (DateTime.now().millisecondsSinceEpoch.toString()),
                          name: name,
                          amount: amount,
                          frequency: frequency,
                          dueDate: dueDate,
                          category: category,
                          isAutoDebit: isAutoDebit,
                          lastPaidDate: existing?.lastPaidDate,
                        );

                        await SubscriptionBillsService.addOrUpdateBill(bill);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        isEditing ? "Update Bill" : "Save Subscription",
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Subscriptions & Bills",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditBillSheet(),
        backgroundColor: const Color(0xFF8B5CF6),
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text("Add Bill",
            style: GoogleFonts.inter(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: ValueListenableBuilder<List<BillSubscription>>(
        valueListenable: SubscriptionBillsService.billsNotifier,
        builder: (context, bills, _) {
          final now = DateTime.now();
          final totalMonthly =
              SubscriptionBillsService.calculateTotalMonthlyCommitment(bills);

          final upcomingCount = bills.where((b) {
            final s = b.getStatus(now);
            return s == BillStatus.upcoming ||
                s == BillStatus.dueToday ||
                s == BillStatus.overdue;
          }).length;

          final paidCount =
              bills.where((b) => b.getStatus(now) == BillStatus.paid).length;

          List<BillSubscription> displayedBills = bills;
          if (_selectedFilter == 1) {
            displayedBills = bills
                .where((b) => b.getStatus(now) != BillStatus.paid)
                .toList();
          } else if (_selectedFilter == 2) {
            displayedBills = bills
                .where((b) => b.getStatus(now) == BillStatus.paid)
                .toList();
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Summary card
              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6D28D9), Color(0xFF8B5CF6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF8B5CF6).withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Total Recurring Outflow",
                        style: GoogleFonts.inter(
                            color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "₹${NumberFormat('#,##,###').format(totalMonthly.round())}",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text("Monthly Average",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        Container(height: 36, width: 1, color: Colors.white24),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "$upcomingCount",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFFDE68A),
                              ),
                            ),
                            Text("Pending Due",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        Container(height: 36, width: 1, color: Colors.white24),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "$paidCount",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF6EE7B7),
                              ),
                            ),
                            Text("Paid Cycle",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Filter segment
              Row(
                children: [
                  _buildFilterChip("All (${bills.length})", 0),
                  const SizedBox(width: 8),
                  _buildFilterChip("Upcoming ($upcomingCount)", 1),
                  const SizedBox(width: 8),
                  _buildFilterChip("Paid ($paidCount)", 2),
                ],
              ),
              const SizedBox(height: 16),
              if (displayedBills.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Column(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 48, color: Colors.blueGrey.shade200),
                        const SizedBox(height: 12),
                        Text("No subscriptions found in this view",
                            style: GoogleFonts.inter(
                                color: Colors.blueGrey.shade400)),
                      ],
                    ),
                  ),
                )
              else
                ...displayedBills.map((b) => _buildDetailedBillCard(
                    context, b, theme, isDark, now)),
              const SizedBox(height: 60),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterChip(String label, int index) {
    final isSelected = _selectedFilter == index;
    return ChoiceChip(
      label: Text(label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : null,
          )),
      selected: isSelected,
      selectedColor: const Color(0xFF8B5CF6),
      onSelected: (_) => setState(() => _selectedFilter = index),
    );
  }

  Widget _buildDetailedBillCard(
    BuildContext context,
    BillSubscription bill,
    ThemeData theme,
    bool isDark,
    DateTime now,
  ) {
    final status = bill.getStatus(now);
    Color statusColor;
    String statusText;

    switch (status) {
      case BillStatus.overdue:
        statusColor = const Color(0xFFEF4444);
        statusText = "Overdue by ${bill.daysUntilDue.abs()} days";
        break;
      case BillStatus.dueToday:
        statusColor = const Color(0xFFF59E0B);
        statusText = "Due Today";
        break;
      case BillStatus.upcoming:
        statusColor = const Color(0xFF2563EB);
        statusText = "Due in ${bill.daysUntilDue} days";
        break;
      case BillStatus.paid:
        statusColor = const Color(0xFF10B981);
        statusText = "Paid for this cycle";
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade200,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.receipt_long,
                        color: statusColor, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.name,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        "${bill.category} • ${bill.frequency.name.toUpperCase()}",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.blueGrey.shade400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    "₹${NumberFormat('#,##,###').format(bill.amount)}",
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _showAddEditBillSheet(bill),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: Colors.redAccent),
                        onPressed: () =>
                            SubscriptionBillsService.deleteBill(bill.id),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.calendar_today, size: 14, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      "${DateFormat('dd MMM yyyy').format(bill.dueDate)} ($statusText)",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
                if (status != BillStatus.paid)
                  ElevatedButton(
                    onPressed: () {
                      final card = UpcomingBillsDashboardCard(
                        accounts: widget.accounts,
                        onViewAllTap: () {},
                      );
                      card._showQuickPaySheet(context, bill);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text("Pay Now",
                        style: GoogleFonts.inter(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  )
                else
                  const Row(
                    children: [
                      Icon(Icons.check, size: 14, color: Color(0xFF10B981)),
                      SizedBox(width: 4),
                      Text("Paid",
                          style: TextStyle(
                              color: Color(0xFF10B981),
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
