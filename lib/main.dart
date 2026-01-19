import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// --- 1. Data Models & Adapters ---

enum AccountType { bank, wallet, credit, cash }

enum TransactionType { expense, transfer, income }

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
  final String? note; // Added note field

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
  });
}

// --- MAIN ENTRY POINT ---

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  Hive.registerAdapter(AccountTypeAdapter());
  Hive.registerAdapter(TransactionTypeAdapter());
  Hive.registerAdapter(TransactionSplitAdapter());
  Hive.registerAdapter(AccountAdapter());
  Hive.registerAdapter(TransactionAdapter());

  await Hive.openBox('expenses_db');

  runApp(const ExpenseTrackerApp());
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
          textTheme: GoogleFonts.interTextTheme(),
          scaffoldBackgroundColor: const Color(0xFFF8FAFC),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            elevation: 0,
            scrolledUnderElevation: 0,
          )),
      home: const WelcomeScreen(),
    );
  }
}

// --- 2. Welcome Screen ---

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  void _getStarted(BuildContext context) {
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const MainAppScaffold()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    color: Colors.blue.shade50, shape: BoxShape.circle),
                child:
                Icon(Icons.wallet, size: 64, color: Colors.blue.shade600),
              ),
              const SizedBox(height: 40),
              Text(
                'Control Your Money',
                style: GoogleFonts.inter(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey.shade900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Track expenses, income, manage accounts, and analyze your financial health with detailed reports.',
                style: GoogleFonts.inter(
                    fontSize: 16, color: Colors.blueGrey.shade500, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () => _getStarted(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: Text('Get Started',
                      style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 3. Main App Scaffold (Multi-Screen Handling) ---

class MainAppScaffold extends StatefulWidget {
  const MainAppScaffold({super.key});

  @override
  State<MainAppScaffold> createState() => _MainAppScaffoldState();
}

class _MainAppScaffoldState extends State<MainAppScaffold> {
  int _currentIndex = 0;
  final Box _box = Hive.box('expenses_db');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
        valueListenable: _box.listenable(),
        builder: (context, Box box, widget) {
          // Load Data from Hive
          final List<Account> accounts = List<Account>.from(
              box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);
          final List<Transaction> transactions = List<Transaction>.from(
              box.get('transactions', defaultValue: [])?.cast<Transaction>() ??
                  []);

          // Initial Category Setup if empty
          if (!box.containsKey('categories')) {
            box.put('categories', {
              'Food': ['Groceries', 'Restaurant', 'Snacks'],
              'Bills': ['Rent', 'Electricity', 'Internet', 'Water', 'Phone'],
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
              'Investment': ['Mutual Funds', 'Stocks', 'FD', 'Gold', 'SIP'],
              'Health': ['Medicine', 'Doctor', 'Insurance'],
              'Entmt': ['Movies', 'Games', 'Events', 'Date'],
            });
          }
          final Map<String, List<String>> categories =
          (box.get('categories') as Map).map((k, v) => MapEntry(
              k.toString(), (v as List).map((e) => e.toString()).toList()));

          final List<Widget> pages = [
            DashboardTab(accounts: accounts, transactions: transactions),
            AccountsTab(accounts: accounts),
            ReportsTab(
                accounts: accounts,
                transactions: transactions), // New Reports Tab
            CategoriesTab(categories: categories),
          ];

          return Scaffold(
            body: pages[_currentIndex],
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: (idx) => setState(() => _currentIndex = idx),
              selectedItemColor: const Color(0xFF2563EB),
              unselectedItemColor: Colors.grey,
              showUnselectedLabels: true,
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.dashboard_outlined),
                    activeIcon: Icon(Icons.dashboard),
                    label: 'Dashboard'),
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
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'Please add an account first (Accounts Tab)!'),
                      backgroundColor: Colors.red));
                  return;
                }
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => AddTransactionSheet(accounts: accounts),
                );
              },
              backgroundColor: const Color(0xFF2563EB),
              child: const Icon(Icons.add, color: Colors.white),
            )
                : null,
          );
        });
  }
}

// --- 4. Dashboard Tab ---

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

  String _formatCurrency(double amount) {
    final format =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    return format.format(amount);
  }

  void _changeMonth(int offset) {
    setState(() {
      _currentMonth =
          DateTime(_currentMonth.year, _currentMonth.month + offset);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Filter Transactions
    final monthlyTransactions = widget.transactions.where((t) {
      return t.date.year == _currentMonth.year &&
          t.date.month == _currentMonth.month;
    }).toList();
    monthlyTransactions.sort((a, b) => b.date.compareTo(a.date));

    // Calculate Total Expense
    final double monthlyExpense = monthlyTransactions.fold(0.0, (sum, t) {
      if (t.type == TransactionType.expense) return sum + t.amount;
      if (t.type == TransactionType.transfer) return sum + t.fee;
      return sum;
    });

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text('Dashboard',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.bold, color: Colors.blueGrey.shade800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Month & Total
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                      color: Colors.blueGrey.withOpacity(0.05),
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
                            color: Colors.blueGrey.shade800)),
                    IconButton(
                        onPressed: () => _changeMonth(1),
                        icon: const Icon(Icons.chevron_right)),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Total Expense',
                    style: GoogleFonts.inter(
                        color: Colors.blueGrey.shade400, fontSize: 14)),
                const SizedBox(height: 4),
                Text(_formatCurrency(monthlyExpense),
                    style: GoogleFonts.inter(
                        color: Colors.blueGrey.shade900,
                        fontSize: 36,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Transactions
          Text('RECENT TRANSACTIONS',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade300,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          if (monthlyTransactions.isEmpty)
            Center(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('No transactions in this month',
                        style: GoogleFonts.inter(
                            color: Colors.blueGrey.shade300))))
          else
            ...monthlyTransactions.take(10).map((txn) =>
                TransactionItem(transaction: txn, accounts: widget.accounts)),

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// --- 5. Accounts Tab ---

class AccountsTab extends StatelessWidget {
  final List<Account> accounts;

  const AccountsTab({super.key, required this.accounts});

  void _showAccountSheet(BuildContext context, {Account? account}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddAccountSheet(existingAccount: account),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
          title: Text('Accounts',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade800))),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAccountSheet(context),
        backgroundColor: const Color(0xFF2563EB),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: accounts.isEmpty
          ? Center(
          child: Text("No accounts yet",
              style: GoogleFonts.inter(color: Colors.grey)))
          : ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: accounts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final acc = accounts[index];
          return GestureDetector(
            onLongPress: () => _showAccountSheet(context, account: acc),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.blueGrey.shade50)),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: acc.color.withOpacity(0.1),
                        shape: BoxShape.circle),
                    child: Icon(acc.icon, color: acc.color, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(acc.name,
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.blueGrey.shade800)),
                        Text(acc.type.name.toUpperCase(),
                            style: GoogleFonts.inter(
                                fontSize: 11,
                                color: Colors.blueGrey.shade400,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Text(
                    NumberFormat.currency(
                        locale: 'en_IN',
                        symbol: '₹',
                        decimalDigits: 0)
                        .format(acc.balance),
                    style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey.shade900),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// --- 6. Reports Tab (UPDATED) ---

class ReportsTab extends StatefulWidget {
  final List<Account> accounts;
  final List<Transaction> transactions;

  const ReportsTab(
      {super.key, required this.accounts, required this.transactions});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  DateTime _currentMonth = DateTime.now();
  bool _isPieChart = false; // Toggle state

  String _formatCurrency(double amount) {
    final format =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    return format.format(amount);
  }

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
          details = details.isEmpty ? "Note: ${t.note}" : "$details | Note: ${t.note}";
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

  // Generate colors for pie chart
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
    // Filter Transactions
    final monthlyTransactions = widget.transactions.where((t) {
      return t.date.year == _currentMonth.year &&
          t.date.month == _currentMonth.month;
    }).toList();

    // Calculate Total Expense
    final double monthlyExpense = monthlyTransactions.fold(0.0, (sum, t) {
      if (t.type == TransactionType.expense) return sum + t.amount;
      if (t.type == TransactionType.transfer) return sum + t.fee;
      return sum;
    });

    // Calculate Breakdown
    final Map<String, double> breakdown = {};
    for (var t in monthlyTransactions) {
      if (t.type == TransactionType.expense) {
        if (t.splits != null && t.splits!.isNotEmpty) {
          for (var split in t.splits!)
            breakdown[split.category] =
                (breakdown[split.category] ?? 0) + split.amount;
        } else {
          breakdown[t.category] = (breakdown[t.category] ?? 0) + t.amount;
        }
      } else if (t.type == TransactionType.transfer && t.fee > 0) {
        breakdown['Transfer Fees'] = (breakdown['Transfer Fees'] ?? 0) + t.fee;
      }
    }
    final sortedBreakdown = Map.fromEntries(
        breakdown.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text('Reports',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.bold, color: Colors.blueGrey.shade800)),
        actions: [
          // View Toggle
          IconButton(
            onPressed: () => setState(() => _isPieChart = !_isPieChart),
            icon: Icon(_isPieChart ? Icons.list : Icons.pie_chart,
                color: Colors.blueGrey.shade700),
            tooltip: _isPieChart ? 'Switch to List' : 'Switch to Pie Chart',
          ),
          // Export Button
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
          // Month Selector
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
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
                        color: Colors.blueGrey.shade800)),
                IconButton(
                    onPressed: () => _changeMonth(1),
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Summary Card
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
                Text(_formatCurrency(monthlyExpense),
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Breakdown View
          if (sortedBreakdown.isNotEmpty) ...[
            Text('CATEGORY BREAKDOWN',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey.shade300,
                    letterSpacing: 1)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(20)),
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

  // --- Helper Widgets ---

  Widget _buildBarList(Map<String, double> data, double total) {
    return Column(
      children: data.entries.map((entry) {
        final percentage = (entry.value / total);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(entry.key,
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey.shade800)),
                Text(_formatCurrency(entry.value),
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey.shade800))
              ]),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                  value: percentage,
                  backgroundColor: Colors.blueGrey.shade50,
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
            ),
            size: const Size(200, 200),
          ),
        ),
        const SizedBox(height: 24),
        // Legend
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
                        style: GoogleFonts.inter(fontSize: 14))),
                Text(_formatCurrency(entry.value),
                    style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// --- Custom Pie Chart Painter ---
class PieChartPainter extends CustomPainter {
  final Map<String, double> data;
  final double total;
  final List<Color> colors;

  PieChartPainter(
      {required this.data, required this.total, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    double startAngle = -pi / 2; // Start from top
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

      // Separator line
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawArc(rect, startAngle, sweepAngle, true, borderPaint);

      startAngle += sweepAngle;
      i++;
    });

    // Donut hole (Optional style)
    final holePaint = Paint()..color = Colors.white;
    canvas.drawCircle(center, radius * 0.5, holePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// --- 7. Categories Tab ---

class CategoriesTab extends StatefulWidget {
  final Map<String, List<String>> categories;

  const CategoriesTab({super.key, required this.categories});

  @override
  State<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends State<CategoriesTab> {
  final Box _box = Hive.box('expenses_db');

  void _updateCategories(Map<String, List<String>> newCats) {
    _box.put('categories', newCats);
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
                // Delete logic
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
                              Navigator.pop(c); // close confirm
                              Navigator.pop(ctx); // close edit
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
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
          title: Text('Categories',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade800))),
      floatingActionButton: FloatingActionButton(
        onPressed: _addCategory,
        backgroundColor: const Color(0xFF2563EB),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: widget.categories.keys.map((cat) {
          final subs = widget.categories[cat]!;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.blueGrey.shade100)),
            child: ExpansionTile(
              title: Text(cat,
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      color: Colors.blueGrey.shade800)),
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
                        backgroundColor: Colors.blue.shade50,
                        side: BorderSide.none,
                      ),
                    )),
                    ActionChip(
                      label:
                      const Icon(Icons.add, size: 16, color: Colors.blue),
                      backgroundColor: Colors.white,
                      side: BorderSide(color: Colors.blue.shade200),
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

// --- 8. Transaction Item Widget (Reusable) ---

class TransactionItem extends StatelessWidget {
  final Transaction transaction;
  final List<Account> accounts;

  const TransactionItem(
      {super.key, required this.transaction, required this.accounts});

  void _deleteTransaction(BuildContext context, String id) {
    // Logic to delete transaction and revert balance
    final box = Hive.box('expenses_db');
    List<Transaction> transactions = List<Transaction>.from(
        box.get('transactions', defaultValue: [])?.cast<Transaction>() ?? []);
    List<Account> accts = List<Account>.from(
        box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);

    final index = transactions.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final txn = transactions[index];

    // Revert logic
    final sourceIndex = accts.indexWhere((a) => a.id == txn.sourceAccountId);
    if (sourceIndex != -1) {
      if (txn.type == TransactionType.expense)
        accts[sourceIndex].balance += txn.amount;
      else if (txn.type == TransactionType.transfer)
        accts[sourceIndex].balance += (txn.amount + txn.fee);
      else if (txn.type == TransactionType.income)
        accts[sourceIndex].balance -= txn.amount;
    }
    if (txn.type == TransactionType.transfer && txn.targetAccountId != null) {
      final targetIndex = accts.indexWhere((a) => a.id == txn.targetAccountId);
      if (targetIndex != -1) accts[targetIndex].balance -= txn.amount;
    }

    transactions.removeAt(index);
    box.put('transactions', transactions);
    box.put('accounts', accts);
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
    String amountText =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0)
        .format(transaction.amount + (isTransfer ? transaction.fee : 0));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16)),
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
                Text(
                    isTransfer
                        ? 'Wallet Transfer'
                        : (isIncome
                        ? 'Income'
                        : (isSplit
                        ? 'Split Expense'
                        : transaction.category)),
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Text(DateFormat('dd MMM').format(transaction.date),
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Colors.blueGrey.shade400)),
                    if (transaction.subCategory != null &&
                        !isTransfer &&
                        !isSplit &&
                        !isIncome)
                      Text(' • ${transaction.subCategory}',
                          style: GoogleFonts.inter(
                              fontSize: 11, color: Colors.blueGrey.shade400)),
                    if (isSplit)
                      Text(' • ${transaction.splits!.length} items',
                          style: GoogleFonts.inter(
                              fontSize: 11, color: Colors.blueGrey.shade400)),
                    if (transaction.fee > 0)
                      Text(' • Fee: ${transaction.fee}',
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
              style:
              GoogleFonts.inter(fontWeight: FontWeight.bold, color: color)),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
            onSelected: (val) {
              if (val == 'edit') _showEditSheet(context);
              if (val == 'delete') _deleteTransaction(context, transaction.id);
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
  final Box _box = Hive.box('expenses_db');

  @override
  void initState() {
    super.initState();
    if (widget.existingAccount != null) {
      _nameCtrl.text = widget.existingAccount!.name;
      _balanceCtrl.text = widget.existingAccount!.balance.toString();
      _selectedType = widget.existingAccount!.type;
      _selectedDate = widget.existingAccount!.createdDate;
    }
  }

  void _save() {
    List<Account> accounts = List<Account>.from(
        _box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);
    final double balance = (widget.existingAccount != null ||
        _selectedType == AccountType.wallet ||
        _selectedType == AccountType.cash)
        ? (double.tryParse(_balanceCtrl.text) ?? 0)
        : 0.0;

    if (widget.existingAccount != null) {
      final index =
      accounts.indexWhere((a) => a.id == widget.existingAccount!.id);
      if (index != -1) {
        accounts[index] = Account(
            id: widget.existingAccount!.id,
            name: _nameCtrl.text,
            balance: balance,
            type: _selectedType,
            createdDate: _selectedDate);
      }
    } else {
      accounts.add(Account(
          id: DateTime.now().millisecondsSinceEpoch,
          name: _nameCtrl.text,
          balance: balance,
          type: _selectedType,
          createdDate: _selectedDate));
    }
    _box.put('accounts', accounts);
    Navigator.pop(context);
  }

  void _delete() {
    List<Account> accounts = List<Account>.from(
        _box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);
    accounts.removeWhere((a) => a.id == widget.existingAccount!.id);
    _box.put('accounts', accounts);
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
    final bool showBalanceField = widget.existingAccount != null ||
        _selectedType == AccountType.wallet ||
        _selectedType == AccountType.cash;
    final bool isEditing = widget.existingAccount != null;

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)))),
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
          if (showBalanceField) ...[
            TextField(
                controller: _balanceCtrl,
                keyboardType: TextInputType.number,
                style: GoogleFonts.inter(
                    fontSize: 24, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                    prefixText: '₹ ', border: InputBorder.none, hintText: '0')),
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
          ] else ...[
            Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text("Opening balance skipped for Banks/Cards.",
                          style: GoogleFonts.inter(
                              fontSize: 12, color: Colors.blue.shade800)))
                ])),
          ],
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
  final Box _box = Hive.box('expenses_db');

  @override
  void initState() {
    super.initState();
    // Load Categories
    _expenseCategories = (_box.get('categories') as Map).map((k, v) =>
        MapEntry(k.toString(), (v as List).map((e) => e.toString()).toList()));
    _selectedCategory = _expenseCategories.keys.first;
    _selectedSubCategory = _expenseCategories[_selectedCategory]?.firstOrNull;

    if (widget.accounts.isNotEmpty) {
      _selectedSourceId = widget.accounts.first.id;
      _selectedTargetId = widget.accounts.length > 1
          ? widget.accounts[1].id
          : widget.accounts.first.id;
    }

    if (widget.existingTransaction != null) {
      final t = widget.existingTransaction!;
      _selectedType = t.type;
      _amountCtrl.text = t.amount.toString();
      _feeCtrl.text = t.fee.toString();
      _noteCtrl.text = t.note ?? '';
      _selectedSourceId = t.sourceAccountId;
      if (t.targetAccountId != null) _selectedTargetId = t.targetAccountId!;
      _selectedCategory = t.category;
      _selectedSubCategory = t.subCategory;
      _selectedDate = t.date;
      if (t.splits != null && t.splits!.isNotEmpty) {
        _isSplitMode = true;
        _currentSplits.addAll(t.splits!);
        _selectedCategory = 'Split';
      } else {
        if (_selectedType == TransactionType.expense &&
            !_expenseCategories.containsKey(_selectedCategory)) {
          _selectedCategory = _expenseCategories.keys.first;
          _selectedSubCategory =
              _expenseCategories[_selectedCategory]?.firstOrNull;
        }
      }
    }
  }

  void _save() {
    final double amount = double.tryParse(_amountCtrl.text) ?? 0;
    final double fee = double.tryParse(_feeCtrl.text) ?? 0;
    if (amount <= 0) return;

    if (_selectedType == TransactionType.expense && _isSplitMode) {
      if (_currentSplits.fold(0.0, (sum, s) => sum + s.amount) != amount) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Split total must match Amount")));
        return;
      }
    }

    List<Transaction> transactions = List<Transaction>.from(
        _box.get('transactions', defaultValue: [])?.cast<Transaction>() ?? []);
    List<Account> accounts = List<Account>.from(
        _box.get('accounts', defaultValue: [])?.cast<Account>() ?? []);

    // 1. If Editing, Revert Old
    if (widget.existingTransaction != null) {
      final oldTxn = widget.existingTransaction!;
      final idx = transactions.indexWhere((t) => t.id == oldTxn.id);
      if (idx != -1) transactions.removeAt(idx);

      final sIdx = accounts.indexWhere((a) => a.id == oldTxn.sourceAccountId);
      if (sIdx != -1) {
        if (oldTxn.type == TransactionType.expense)
          accounts[sIdx].balance += oldTxn.amount;
        else if (oldTxn.type == TransactionType.transfer)
          accounts[sIdx].balance += (oldTxn.amount + oldTxn.fee);
        else if (oldTxn.type == TransactionType.income)
          accounts[sIdx].balance -= oldTxn.amount;
      }
      if (oldTxn.type == TransactionType.transfer &&
          oldTxn.targetAccountId != null) {
        final tIdx = accounts.indexWhere((a) => a.id == oldTxn.targetAccountId);
        if (tIdx != -1) accounts[tIdx].balance -= oldTxn.amount;
      }
    }

    // 2. Create New
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
      splits: _isSplitMode ? _currentSplits : null,
      note: _noteCtrl.text.isEmpty ? null : _noteCtrl.text,
    );

    // 3. Apply New Balance
    final sIdx = accounts.indexWhere((a) => a.id == newTxn.sourceAccountId);
    if (sIdx != -1) {
      if (newTxn.type == TransactionType.expense)
        accounts[sIdx].balance -= newTxn.amount;
      else if (newTxn.type == TransactionType.transfer)
        accounts[sIdx].balance -= (newTxn.amount + newTxn.fee);
      else if (newTxn.type == TransactionType.income)
        accounts[sIdx].balance += newTxn.amount;
    }
    if (newTxn.type == TransactionType.transfer &&
        newTxn.targetAccountId != null) {
      final tIdx = accounts.indexWhere((a) => a.id == newTxn.targetAccountId);
      if (tIdx != -1) accounts[tIdx].balance += newTxn.amount;
    }

    transactions.add(newTxn);
    // Sort
    transactions.sort((a, b) => b.date.compareTo(a.date));

    _box.put('transactions', transactions);
    _box.put('accounts', accounts);
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
    if (amt > 0) {
      setState(() {
        _currentSplits.add(TransactionSplit(
            amount: amt,
            category: _selectedCategory,
            subCategory: _selectedSubCategory));
        _splitAmountCtrl.clear();
      });
    }
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

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
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
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: Colors.grey.shade100,
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
                          _selectedCategory = _expenseCategories.keys.first;
                          _selectedSubCategory =
                              _expenseCategories[_selectedCategory]
                                  ?.firstOrNull;
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                            color:
                            isSelected ? Colors.white : Colors.transparent,
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
                                    ? Colors.black
                                    : Colors.grey.shade600)),
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
                      border: Border.all(color: Colors.grey.shade200),
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.calendar_today,
                        size: 18, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    Text(DateFormat('dd MMM yyyy').format(_selectedDate),
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w500,
                            color: Colors.blueGrey.shade800)),
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
                onChanged: (val) => setState(() {}),
                style: GoogleFonts.inter(
                    fontSize: 24, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                    labelText: "AMOUNT",
                    prefixText: '₹ ',
                    border: InputBorder.none)),
            const Divider(),
            const SizedBox(height: 16),
            Text(
                _selectedType == TransactionType.income ? 'DEPOSIT TO' : 'FROM',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade400)),
            DropdownButton<int>(
                value: _selectedSourceId,
                isExpanded: true,
                underline: const SizedBox(),
                items: widget.accounts
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
                  items: widget.accounts
                      .where((a) => a.id != _selectedSourceId)
                      .map((a) =>
                      DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (val) => setState(() => _selectedTargetId = val!)),
              const SizedBox(height: 16),
              TextField(
                  controller: _feeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: "FEE",
                      prefixText: '₹ ',
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
                  children: _incomeCategories
                      .map((c) => ChoiceChip(
                      label: Text(c),
                      selected: _selectedCategory == c,
                      onSelected: (val) =>
                          setState(() => _selectedCategory = c),
                      selectedColor: Colors.green.shade100))
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
                            Text('₹${entry.value.amount.toInt()}',
                                style: GoogleFonts.inter(
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                onPressed: () => setState(
                                        () => _currentSplits.removeAt(entry.key)),
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.red))
                          ]))),
                      const Divider(),
                      if (remaining > 0) ...[
                        Row(children: [
                          Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                  value: _selectedCategory,
                                  isExpanded: true,
                                  underline: const SizedBox(),
                                  items: _expenseCategories.keys
                                      .map((c) => DropdownMenuItem(
                                      value: c, child: Text(c)))
                                      .toList(),
                                  onChanged: (val) => setState(() {
                                    _selectedCategory = val!;
                                    _selectedSubCategory =
                                        _expenseCategories[val]
                                            ?.firstOrNull;
                                  }))),
                          const SizedBox(width: 8),
                          Expanded(
                              flex: 2,
                              child: DropdownButton<String>(
                                  value: _selectedSubCategory,
                                  isExpanded: true,
                                  underline: const SizedBox(),
                                  items:
                                  (_expenseCategories[_selectedCategory] ??
                                      [])
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
                                  decoration: InputDecoration(
                                      hintText: 'Remaining: $remaining',
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
                        children: _expenseCategories.keys
                            .map((c) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                                label: Text(c),
                                selected: _selectedCategory == c,
                                onSelected: (val) => setState(() {
                                  _selectedCategory = c;
                                  _selectedSubCategory =
                                      _expenseCategories[c]
                                          ?.firstOrNull;
                                }),
                                selectedColor: Colors.blue.shade100)))
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
                      children: _expenseCategories[_selectedCategory]!
                          .map((sub) => ChoiceChip(
                          label: Text(sub),
                          selected: _selectedSubCategory == sub,
                          onSelected: (val) =>
                              setState(() => _selectedSubCategory = sub),
                          selectedColor: Colors.blue.shade100))
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

// --- TYPE ADAPTERS ---

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
    final splits = reader.readBool() ? (reader.readList().cast<TransactionSplit>()) : null;

    String? note;
    if (reader.availableBytes > 0) {
      if(reader.readBool()) {
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