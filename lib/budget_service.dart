import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:intl/intl.dart';
import 'main.dart' show Transaction, TransactionType, AuthService;

class CategoryBudget {
  final String category;
  final double monthlyLimit;
  final double alertThreshold; // e.g. 0.8 for 80%
  final DateTime updatedAt;

  CategoryBudget({
    required this.category,
    required this.monthlyLimit,
    this.alertThreshold = 0.8,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'category': category,
      'monthlyLimit': monthlyLimit,
      'alertThreshold': alertThreshold,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory CategoryBudget.fromMap(Map<dynamic, dynamic> map) {
    return CategoryBudget(
      category: map['category']?.toString() ?? '',
      monthlyLimit: (map['monthlyLimit'] as num?)?.toDouble() ?? 0.0,
      alertThreshold: (map['alertThreshold'] as num?)?.toDouble() ?? 0.8,
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  CategoryBudget copyWith({
    String? category,
    double? monthlyLimit,
    double? alertThreshold,
    DateTime? updatedAt,
  }) {
    return CategoryBudget(
      category: category ?? this.category,
      monthlyLimit: monthlyLimit ?? this.monthlyLimit,
      alertThreshold: alertThreshold ?? this.alertThreshold,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class CategoryBudgetStatus {
  final CategoryBudget budget;
  final double spent;
  final double limit;
  final double remaining;
  final double percentage; // 0.0 to 1.0+
  final bool isNearLimit;
  final bool isOverBudget;
  final double dailyBurnRate;
  final int daysRemainingInMonth;

  CategoryBudgetStatus({
    required this.budget,
    required this.spent,
    required this.limit,
    required this.remaining,
    required this.percentage,
    required this.isNearLimit,
    required this.isOverBudget,
    required this.dailyBurnRate,
    required this.daysRemainingInMonth,
  });

  Color get statusColor {
    if (isOverBudget) return const Color(0xFFEF4444); // Red
    if (isNearLimit) return const Color(0xFFF59E0B); // Amber
    return const Color(0xFF10B981); // Emerald
  }

  String get statusMessage {
    if (isOverBudget) {
      final over = spent - limit;
      return "Over budget by ₹${NumberFormat('#,##,###').format(over)}";
    }
    if (isNearLimit) {
      return "Near limit (${(percentage * 100).toStringAsFixed(0)}% used)";
    }
    return "On track (${(percentage * 100).toStringAsFixed(0)}% used)";
  }
}

class BudgetService {
  static Box? _budgetBox;
  static final ValueNotifier<List<CategoryBudget>> budgetsNotifier =
      ValueNotifier<List<CategoryBudget>>([]);

  static Future<void> initialize() async {
    _budgetBox = await Hive.openBox('category_budgets');
    _loadFromHive();
    final user = AuthService.currentUser;
    if (user != null) {
      syncFromFirestore(user.uid);
    }
  }

  static void _loadFromHive() {
    if (_budgetBox == null) return;
    final list = <CategoryBudget>[];
    for (var key in _budgetBox!.keys) {
      final val = _budgetBox!.get(key);
      if (val is Map) {
        list.add(CategoryBudget.fromMap(val));
      }
    }
    list.sort((a, b) => b.monthlyLimit.compareTo(a.monthlyLimit));
    budgetsNotifier.value = list;
  }

  static Future<void> setBudget(CategoryBudget budget) async {
    if (_budgetBox == null) _budgetBox = await Hive.openBox('category_budgets');
    await _budgetBox!.put(budget.category, budget.toMap());
    _loadFromHive();

    final user = AuthService.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('budgets')
            .doc(budget.category)
            .set(budget.toMap());
      } catch (e) {
        debugPrint("Error syncing budget to Firestore: $e");
      }
    }
  }

  static Future<void> deleteBudget(String category) async {
    if (_budgetBox != null) {
      await _budgetBox!.delete(category);
      _loadFromHive();
    }
    final user = AuthService.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('budgets')
            .doc(category)
            .delete();
      } catch (e) {
        debugPrint("Error deleting budget in Firestore: $e");
      }
    }
  }

  static Future<void> syncFromFirestore(String userId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('budgets')
          .get();

      if (snapshot.docs.isNotEmpty && _budgetBox != null) {
        for (var doc in snapshot.docs) {
          final data = doc.data();
          await _budgetBox!.put(doc.id, data);
        }
        _loadFromHive();
      }
    } catch (e) {
      debugPrint("Error syncing budgets from Firestore: $e");
    }
  }

  static double calculateCategorySpent(
    String category,
    List<Transaction> transactions, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    double spent = 0.0;

    for (var t in transactions) {
      if (t.type != TransactionType.expense) continue;
      if (t.date.year != current.year || t.date.month != current.month) continue;

      if (t.splits != null && t.splits!.isNotEmpty) {
        for (var s in t.splits!) {
          if (s.category.toLowerCase() == category.toLowerCase()) {
            spent += s.amount;
          }
        }
      } else if (t.category.toLowerCase() == category.toLowerCase()) {
        spent += t.amount;
      }
    }
    return spent;
  }

  static CategoryBudgetStatus getStatus(
    CategoryBudget budget,
    List<Transaction> transactions, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final spent = calculateCategorySpent(budget.category, transactions, now: current);
    final limit = budget.monthlyLimit;
    final remaining = max(0.0, limit - spent);
    final percentage = limit > 0 ? (spent / limit) : 0.0;

    final daysInMonth = DateTime(current.year, current.month + 1, 0).day;
    final daysRemaining = max(1, daysInMonth - current.day + 1);
    final dailyBurnRate = remaining / daysRemaining;

    final isOver = spent > limit;
    final isNear = !isOver && (percentage >= budget.alertThreshold);

    return CategoryBudgetStatus(
      budget: budget,
      spent: spent,
      limit: limit,
      remaining: remaining,
      percentage: percentage,
      isNearLimit: isNear,
      isOverBudget: isOver,
      dailyBurnRate: dailyBurnRate,
      daysRemainingInMonth: daysRemaining,
    );
  }
}

// --- UI Components ---

class BudgetOverviewCard extends StatelessWidget {
  final List<Transaction> transactions;
  final VoidCallback onManageTap;

  const BudgetOverviewCard({
    super.key,
    required this.transactions,
    required this.onManageTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ValueListenableBuilder<List<CategoryBudget>>(
      valueListenable: BudgetService.budgetsNotifier,
      builder: (context, budgets, _) {
        if (budgets.isEmpty) {
          return _buildEmptyBudgetCard(context, theme, isDark);
        }

        double totalBudget = 0.0;
        double totalSpent = 0.0;
        int overBudgetCount = 0;

        final statuses = budgets.map((b) {
          final s = BudgetService.getStatus(b, transactions);
          totalBudget += s.limit;
          totalSpent += s.spent;
          if (s.isOverBudget) overBudgetCount++;
          return s;
        }).toList();

        final totalRemaining = max(0.0, totalBudget - totalSpent);
        final overallPercent = totalBudget > 0 ? (totalSpent / totalBudget).clamp(0.0, 1.0) : 0.0;

        final now = DateTime.now();
        final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
        final daysLeft = max(1, daysInMonth - now.day + 1);
        final overallBurnRate = totalRemaining / daysLeft;

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
                          color: const Color(0xFF2563EB).withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.pie_chart_outline,
                            color: Color(0xFF2563EB), size: 20),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Monthly Budgets",
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            overBudgetCount > 0
                                ? "$overBudgetCount category over limit"
                                : "Spending limits on track",
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: overBudgetCount > 0
                                  ? const Color(0xFFEF4444)
                                  : Colors.blueGrey.shade400,
                              fontWeight: overBudgetCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: onManageTap,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text("Manage"),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      textStyle: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Overall progress
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "₹${NumberFormat('#,##,###').format(totalSpent)} spent",
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    "Limit: ₹${NumberFormat('#,##,###').format(totalBudget)}",
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.blueGrey.shade400,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: overallPercent,
                  minHeight: 10,
                  backgroundColor: isDark
                      ? Colors.white.withOpacity(0.08)
                      : Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    totalSpent > totalBudget
                        ? const Color(0xFFEF4444)
                        : (overallPercent >= 0.85
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF10B981)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Burn rate banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department,
                        size: 16,
                        color: overallPercent >= 0.85
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF2563EB)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Daily Burn Rate: ₹${NumberFormat('#,##,###').format(overallBurnRate.round())}/day safe spend ($daysLeft days left)",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Top 3 category breakdown
              ...statuses.take(3).map((s) => _buildMiniCategoryRow(s, theme, isDark)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyBudgetCard(
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
                  color: const Color(0xFF2563EB).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.pie_chart_outline,
                    color: Color(0xFF2563EB), size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                "Category Budgets",
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
            "Take control of your spending. Set monthly limits for Food, Shopping, and Bills to get daily burn-rate insights.",
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
              onPressed: onManageTap,
              icon: const Icon(Icons.add, size: 18),
              label: const Text("Set Monthly Budgets"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
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

  Widget _buildMiniCategoryRow(
      CategoryBudgetStatus status, ThemeData theme, bool isDark) {
    final percentClamped = status.percentage.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                status.budget.category,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                "₹${NumberFormat('#,##,###').format(status.spent)} / ₹${NumberFormat('#,##,###').format(status.limit)}",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: status.statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percentClamped,
              minHeight: 6,
              backgroundColor: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(status.statusColor),
            ),
          ),
        ],
      ),
    );
  }
}

class BudgetsScreen extends StatefulWidget {
  final List<Transaction> transactions;

  const BudgetsScreen({super.key, required this.transactions});

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  final List<String> _availableCategories = [
    'Food',
    'Bills',
    'Transport',
    'Shopping',
    'Personal Care',
    'Skill Dev',
    'Investment',
    'Health',
    'Entmt',
    'Other',
  ];

  void _showAddEditBudgetSheet([CategoryBudget? existing]) {
    final isEditing = existing != null;
    String selectedCategory = existing?.category ?? _availableCategories.first;
    final limitController = TextEditingController(
      text: existing != null ? existing.monthlyLimit.toStringAsFixed(0) : '',
    );
    double alertThreshold = existing?.alertThreshold ?? 0.8;

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
                Text(
                  isEditing ? "Edit Budget" : "Set Category Budget",
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 20),
                Text("Category",
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  items: _availableCategories
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c, style: GoogleFonts.inter()),
                          ))
                      .toList(),
                  onChanged: isEditing
                      ? null
                      : (val) {
                          if (val != null) {
                            setSheetState(() => selectedCategory = val);
                          }
                        },
                ),
                const SizedBox(height: 20),
                Text("Monthly Spending Limit (₹)",
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                TextField(
                  controller: limitController,
                  keyboardType: TextInputType.number,
                  autofocus: !isEditing,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.currency_rupee, size: 20),
                    hintText: "e.g. 10000",
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                // Quick preset pills
                Row(
                  children: [5000, 10000, 20000].map((preset) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text("₹$preset",
                            style: GoogleFonts.inter(fontSize: 12)),
                        onPressed: () {
                          setSheetState(() {
                            limitController.text = preset.toString();
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Warning Alert Threshold",
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant)),
                    Text("${(alertThreshold * 100).toInt()}%",
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF2563EB))),
                  ],
                ),
                Slider(
                  value: alertThreshold,
                  min: 0.5,
                  max: 0.95,
                  divisions: 9,
                  label: "${(alertThreshold * 100).toInt()}%",
                  activeColor: const Color(0xFF2563EB),
                  onChanged: (val) {
                    setSheetState(() => alertThreshold = val);
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      final amount = double.tryParse(limitController.text.trim());
                      if (amount == null || amount <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text("Please enter a valid amount")),
                        );
                        return;
                      }

                      final b = CategoryBudget(
                        category: selectedCategory,
                        monthlyLimit: amount,
                        alertThreshold: alertThreshold,
                      );
                      await BudgetService.setBudget(b);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      isEditing ? "Update Budget" : "Save Budget",
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

  void _applyDefaultPresets() async {
    final presets = [
      CategoryBudget(category: 'Food', monthlyLimit: 12000),
      CategoryBudget(category: 'Bills', monthlyLimit: 15000),
      CategoryBudget(category: 'Transport', monthlyLimit: 4000),
      CategoryBudget(category: 'Shopping', monthlyLimit: 6000),
      CategoryBudget(category: 'Entmt', monthlyLimit: 3000),
    ];
    for (var b in presets) {
      await BudgetService.setBudget(b);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Applied standard budget presets")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Category Budgets",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: "Set Standard Presets",
            onPressed: _applyDefaultPresets,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditBudgetSheet(),
        backgroundColor: const Color(0xFF2563EB),
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text("Set Budget",
            style: GoogleFonts.inter(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: ValueListenableBuilder<List<CategoryBudget>>(
        valueListenable: BudgetService.budgetsNotifier,
        builder: (context, budgets, _) {
          if (budgets.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.pie_chart_outline,
                        size: 64, color: Colors.blueGrey.shade200),
                    const SizedBox(height: 16),
                    Text(
                      "No category budgets set",
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Set limits to monitor your spending and get daily burn rate advice.",
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: Colors.blueGrey.shade400,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _applyDefaultPresets,
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text("Apply Suggested Budgets"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final statuses = budgets
              .map((b) => BudgetService.getStatus(b, widget.transactions))
              .toList();

          double totalLimit = 0.0;
          double totalSpent = 0.0;
          for (var s in statuses) {
            totalLimit += s.limit;
            totalSpent += s.spent;
          }
          final totalRemaining = max(0.0, totalLimit - totalSpent);

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Summary card
              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2563EB).withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Monthly Budget Summary",
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
                              "₹${NumberFormat('#,##,###').format(totalLimit)}",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text("Total Budget",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        Container(
                          height: 36,
                          width: 1,
                          color: Colors.white24,
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "₹${NumberFormat('#,##,###').format(totalSpent)}",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text("Total Spent",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        Container(
                          height: 36,
                          width: 1,
                          color: Colors.white24,
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "₹${NumberFormat('#,##,###').format(totalRemaining)}",
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF6EE7B7),
                              ),
                            ),
                            Text("Remaining",
                                style: GoogleFonts.inter(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Category Breakdown",
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 14),
              ...statuses.map((s) => _buildBudgetDetailCard(s, theme, isDark)),
              const SizedBox(height: 60), // FAB spacing
            ],
          );
        },
      ),
    );
  }

  Widget _buildBudgetDetailCard(
      CategoryBudgetStatus status, ThemeData theme, bool isDark) {
    final percentClamped = status.percentage.clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
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
      padding: const EdgeInsets.all(18),
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
                      color: status.statusColor.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.category_outlined,
                        color: status.statusColor, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.budget.category,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        status.statusMessage,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: status.statusColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _showAddEditBudgetSheet(status.budget),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: Colors.redAccent),
                    onPressed: () =>
                        BudgetService.deleteBudget(status.budget.category),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Spent: ₹${NumberFormat('#,##,###').format(status.spent)}",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                "Limit: ₹${NumberFormat('#,##,###').format(status.limit)}",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.blueGrey.shade400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: percentClamped,
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(status.statusColor),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Remaining: ₹${NumberFormat('#,##,###').format(status.remaining)}",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  "Burn rate: ₹${NumberFormat('#,##,###').format(status.dailyBurnRate.round())}/day",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: status.dailyBurnRate > 0
                        ? const Color(0xFF2563EB)
                        : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
