import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:expense_tracker/main.dart';
import 'package:expense_tracker/notification_tracking_service.dart';
import 'package:expense_tracker/budget_service.dart';
import 'package:expense_tracker/subscription_bills_service.dart';

void main() {
  group('EncryptionService Tests', () {
    test('String encryption and decryption', () {
      const original = 'SecretText123';
      final encrypted = EncryptionService.encrypt(original);
      final decrypted = EncryptionService.decrypt(encrypted);

      expect(decrypted, original);
      expect(encrypted, isNot(original));
      expect(encrypted, contains(':')); // Check for IV:Cipher format
    });

    test('Double encryption and decryption', () {
      const original = 12345.67;
      final encrypted = EncryptionService.encryptDouble(original);
      final decrypted = EncryptionService.decryptDouble(encrypted);

      expect(decrypted, original);
    });

    test('Decryption of plain text returns original (Legacy/Error support)', () {
      const original = 'PlainText';
      final decrypted = EncryptionService.decrypt(original);
      expect(decrypted, original);
    });
  });

  group('Model Serialization Tests', () {
    test('Account serialization', () {
      final account = Account(
        id: 1,
        name: 'Test Bank',
        balance: 5000.0,
        type: AccountType.bank,
        createdDate: DateTime.now(),
      );

      final map = account.toMap();

      // Check that sensitive fields are encrypted in the map
      expect(map['name'], isNot('Test Bank'));
      expect(map['balance'], isNot(5000.0));

      final reconstructed = Account.fromMap(map);

      expect(reconstructed.id, account.id);
      expect(reconstructed.name, account.name);
      expect(reconstructed.balance, account.balance);
      expect(reconstructed.type, account.type);
    });

    test('Transaction serialization with Recurrence', () {
      final now = DateTime.now();
      final txn = Transaction(
        id: 'txn1',
        amount: 100.0,
        type: TransactionType.expense,
        sourceAccountId: 1,
        category: 'Food',
        date: now,
        recurrence: RecurrenceFrequency.monthly,
        note: 'Monthly Subscription',
      );

      final map = txn.toMap();

      // Verify Enum is stored as index
      expect(map['recurrence'], RecurrenceFrequency.monthly.index);
      // Verify Note is encrypted
      expect(map['note'], isNot('Monthly Subscription'));

      final reconstructed = Transaction.fromMap(map);

      expect(reconstructed.recurrence, RecurrenceFrequency.monthly);
      expect(reconstructed.amount, 100.0);
      expect(reconstructed.note, 'Monthly Subscription');
      // Verify date timestamp (allow small delta for precision loss if any)
      expect(reconstructed.date.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    });
  });

  group('Recurrence Logic & Generation Tests', () {
    // --- 1. Logic Helper (Copied from main.dart for Isolation) ---
    DateTime calculateNextDueDate(DateTime currentDate, RecurrenceFrequency recurrence) {
      DateTime nextDueDate = currentDate;
      switch (recurrence) {
        case RecurrenceFrequency.daily:
          nextDueDate = nextDueDate.add(const Duration(days: 1));
          break;
        case RecurrenceFrequency.weekly:
          nextDueDate = nextDueDate.add(const Duration(days: 7));
          break;
        case RecurrenceFrequency.monthly:
          int newMonth = nextDueDate.month + 1;
          int newYear = nextDueDate.year;
          if (newMonth > 12) {
            newMonth = 1;
            newYear++;
          }
          int lastDay = DateTime(newYear, newMonth + 1, 0).day;
          int newDay = min(currentDate.day, lastDay);
          nextDueDate = DateTime(newYear, newMonth, newDay);
          break;
        case RecurrenceFrequency.yearly:
          if (currentDate.month == 2 && currentDate.day == 29) {
            final isLeap = (nextDueDate.year + 1) % 4 == 0 &&
                ((nextDueDate.year + 1) % 100 != 0 || (nextDueDate.year + 1) % 400 == 0);
            nextDueDate = DateTime(nextDueDate.year + 1, 2, isLeap ? 29 : 28);
          } else {
            nextDueDate = DateTime(nextDueDate.year + 1, nextDueDate.month, nextDueDate.day);
          }
          break;
        case RecurrenceFrequency.none:
          break;
      }
      return nextDueDate;
    }

    // --- 2. Date Calculation Tests ---
    test('Daily adds 1 day', () {
      final start = DateTime(2024, 1, 1);
      expect(calculateNextDueDate(start, RecurrenceFrequency.daily), DateTime(2024, 1, 2));
    });

    test('Weekly adds 7 days', () {
      final start = DateTime(2024, 1, 1);
      expect(calculateNextDueDate(start, RecurrenceFrequency.weekly), DateTime(2024, 1, 8));
    });

    test('Monthly handles Jan 31 -> Feb 29 (Leap Year)', () {
      final start = DateTime(2024, 1, 31);
      expect(calculateNextDueDate(start, RecurrenceFrequency.monthly), DateTime(2024, 2, 29));
    });

    test('Monthly handles Jan 31 -> Feb 28 (Non-Leap Year)', () {
      final start = DateTime(2023, 1, 31);
      expect(calculateNextDueDate(start, RecurrenceFrequency.monthly), DateTime(2023, 2, 28));
    });

    test('Monthly handles Dec -> Jan rollover', () {
      final start = DateTime(2023, 12, 15);
      expect(calculateNextDueDate(start, RecurrenceFrequency.monthly), DateTime(2024, 1, 15));
    });

    // --- 3. Generation Logic Simulation ---
    test('Should identify missing recurring transactions', () {
      // Setup: A monthly transaction created 2 months ago
      final baseDate = DateTime(2023, 1, 15);
      final recurringTxn = Transaction(
        id: 'orig_1',
        amount: 500,
        type: TransactionType.expense,
        sourceAccountId: 1,
        category: 'Rent',
        date: baseDate,
        recurrence: RecurrenceFrequency.monthly,
      );

      // Current state: Only the original exists
      final currentTransactions = [recurringTxn];

      // Mock "Today" as 2 months later (March 20th)
      final mockToday = DateTime(2023, 3, 20);

      // --- Logic Simulation (Simplified version of main.dart logic) ---
      final generatedTxns = <Transaction>[];
      DateTime nextDueDate = recurringTxn.date;

      while (true) {
        nextDueDate = calculateNextDueDate(nextDueDate, recurringTxn.recurrence);

        if (nextDueDate.isAfter(mockToday)) break;

        // Check exists
        bool exists = currentTransactions.any((t) =>
        t.amount == recurringTxn.amount &&
            t.category == recurringTxn.category &&
            t.date.year == nextDueDate.year &&
            t.date.month == nextDueDate.month &&
            t.date.day == nextDueDate.day);

        if (!exists) {
          generatedTxns.add(Transaction(
            id: 'new_${nextDueDate.month}',
            amount: recurringTxn.amount,
            type: recurringTxn.type,
            sourceAccountId: recurringTxn.sourceAccountId,
            category: recurringTxn.category,
            date: nextDueDate,
            recurrence: RecurrenceFrequency.none,
          ));
        }
      }
      // ----------------------------------------------------------------

      // Assertions:
      // Should generate Feb 15 and Mar 15 transactions
      expect(generatedTxns.length, 2);
      expect(generatedTxns[0].date, DateTime(2023, 2, 15));
      expect(generatedTxns[1].date, DateTime(2023, 3, 15));
    });

    test('Should NOT generate duplicates if transaction already exists', () {
      final baseDate = DateTime(2023, 1, 15);
      final recurringTxn = Transaction(
        id: 'orig_1',
        amount: 500,
        type: TransactionType.expense,
        sourceAccountId: 1,
        category: 'Rent',
        date: baseDate,
        recurrence: RecurrenceFrequency.monthly,
      );

      // Current state: Original + The next month's payment already manually added
      final manualPayment = Transaction(
        id: 'manual_1',
        amount: 500,
        type: TransactionType.expense,
        sourceAccountId: 1,
        category: 'Rent',
        date: DateTime(2023, 2, 15), // Matches expected due date
        recurrence: RecurrenceFrequency.none,
      );

      final currentTransactions = [recurringTxn, manualPayment];

      // Mock "Today" as Feb 20th
      final mockToday = DateTime(2023, 2, 20);

      // --- Logic Simulation ---
      final generatedTxns = <Transaction>[];
      DateTime nextDueDate = recurringTxn.date;

      while (true) {
        nextDueDate = calculateNextDueDate(nextDueDate, recurringTxn.recurrence);
        if (nextDueDate.isAfter(mockToday)) break;

        bool exists = currentTransactions.any((t) =>
        t.amount == recurringTxn.amount &&
            t.category == recurringTxn.category &&
            t.date.year == nextDueDate.year &&
            t.date.month == nextDueDate.month &&
            t.date.day == nextDueDate.day);

        if (!exists) {
          generatedTxns.add(Transaction(
              id: 'new', amount: 0, type: TransactionType.expense, sourceAccountId: 0, category: '', date: DateTime.now()
          ));
        }
      }
      // ------------------------

      // Assertions:
      // Should generate 0 transactions because Feb 15 exists
      expect(generatedTxns.length, 0);
    });
  });

 
  group('FinanceCalculator Tests', () {
    test('calculateIncome sums only income transactions', () {
      final txns = [
        Transaction(
            id: '1', amount: 100, type: TransactionType.income, sourceAccountId: 1, category: 'Salary', date: DateTime.now()),
        Transaction(
            id: '2', amount: 50, type: TransactionType.expense, sourceAccountId: 1, category: 'Food', date: DateTime.now()),
        Transaction(
            id: '3', amount: 200, type: TransactionType.income, sourceAccountId: 1, category: 'Bonus', date: DateTime.now()),
      ];
      final income = FinanceCalculator.calculateIncome(txns);
      expect(income, 300.0);
    });

    test('calculateExpense sums expenses and transfer fees', () {
      final txns = [
        Transaction(
            id: '1', amount: 100, type: TransactionType.income, sourceAccountId: 1, category: 'Salary', date: DateTime.now()),
        Transaction(
            id: '2', amount: 50, type: TransactionType.expense, sourceAccountId: 1, category: 'Food', date: DateTime.now()),
        Transaction(
            id: '3', amount: 200, fee: 5.0, type: TransactionType.transfer, sourceAccountId: 1, targetAccountId: 2, category: 'Transfer', date: DateTime.now()),
      ];
      final expense = FinanceCalculator.calculateExpense(txns);
      expect(expense, 55.0); // 50 expense + 5 fee
    });

    test('calculateBreakdown by Category (Simple)', () {
      final txns = [
        Transaction(
            id: '1', amount: 50, type: TransactionType.expense, sourceAccountId: 1, category: 'Food', date: DateTime.now()),
        Transaction(
            id: '2', amount: 30, type: TransactionType.expense, sourceAccountId: 1, category: 'Transport', date: DateTime.now()),
        Transaction(
            id: '3', amount: 20, type: TransactionType.expense, sourceAccountId: 1, category: 'Food', date: DateTime.now()),
      ];
      final accounts = [Account(id: 1, name: 'Bank', balance: 0, type: AccountType.bank, createdDate: DateTime.now())];

      final breakdown = FinanceCalculator.calculateBreakdown(
          transactions: txns,
          accounts: accounts,
          reportType: ReportType.category);

      expect(breakdown['Food'], 70.0);
      expect(breakdown['Transport'], 30.0);
    });

    test('calculateBreakdown by Category (Splits)', () {
      final txns = [
        Transaction(
            id: '1',
            amount: 100,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Mixed',
            date: DateTime.now(),
            splits: [
              TransactionSplit(amount: 60, category: 'Food'),
              TransactionSplit(amount: 40, category: 'Entertainment', subCategory: 'Movie'),
            ]
        ),
      ];
      final accounts = [Account(id: 1, name: 'Bank', balance: 0, type: AccountType.bank, createdDate: DateTime.now())];

      final breakdown = FinanceCalculator.calculateBreakdown(
          transactions: txns,
          accounts: accounts,
          reportType: ReportType.category);

      expect(breakdown['Food'], 60.0);
      expect(breakdown['Entertainment - Movie'], 40.0);
    });

    test('calculateBreakdown by Account Type', () {
      final accounts = [
        Account(id: 1, name: 'Main Bank', balance: 0, type: AccountType.bank, createdDate: DateTime.now()),
        Account(id: 2, name: 'Cash Wallet', balance: 0, type: AccountType.wallet, createdDate: DateTime.now()),
      ];
      final txns = [
        Transaction(
            id: '1', amount: 50, type: TransactionType.expense, sourceAccountId: 1, category: 'Food', date: DateTime.now()),
        Transaction(
            id: '2', amount: 30, type: TransactionType.expense, sourceAccountId: 2, category: 'Transport', date: DateTime.now()),
      ];

      final breakdown = FinanceCalculator.calculateBreakdown(
          transactions: txns,
          accounts: accounts,
          reportType: ReportType.accountType);

      expect(breakdown['Bank'], 50.0);
      expect(breakdown['Wallet'], 30.0);
    });

    group('Notification Parser & False-Positive Filtering Tests', () {
      test('Rejects Google Finance stock update notification', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: '544773 is up 4.5%',
          content: 'Merritronix LTD rose to ₹414.80 today',
          packageName: 'com.google.android.googlequicksearchbox',
        );
        expect(result, isNull);
      });

      test('Rejects generic stock market alert', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'Market Alert: NIFTY 50',
          content: 'NIFTY 50 is trading at ₹24,850.00 today, up by 150 points',
          packageName: 'com.divum.MoneyControl',
        );
        expect(result, isNull);
      });

      test('Rejects promotional and discount messages', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'Special Offer!',
          content: 'Get flat ₹200 off on your next order! Use code SAVE200',
          packageName: 'com.phonepe.app',
        );
        expect(result, isNull);
      });

      test('Rejects OTP and security verification codes', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'HDFC Bank',
          content:
              'Your OTP for txn of INR 500.00 is 123456. Do not share with anyone.',
          packageName: 'com.google.android.apps.messaging',
        );
        expect(result, isNull);
      });

      test('Rejects future bill due notices', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'Airtel Broadband',
          content:
              'Your bill of ₹999.00 is due on 15-Oct. Pay before due date to avoid penalty.',
          packageName: 'com.google.android.apps.messaging',
        );
        expect(result, isNull);
      });

      test('Parses genuine Google Pay payment', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'Google Pay',
          content: 'Paid ₹249.0 to Swiggy',
          packageName: 'com.google.android.apps.nbu.paisa.user',
        );
        expect(result, isNotNull);
        expect(result!.amount, 249.0);
        expect(result.payee, 'Swiggy');
        expect(result.category, 'Food');
        expect(result.type, DetectedTransactionType.expense);
      });

      test('Parses genuine Bank SMS debit', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'HDFCBK',
          content:
              '₹540.00 debited from a/c ending 1234 on 12-Oct-26 to ZOMATO. Avl Bal: ₹25,000.00',
          packageName: 'com.google.android.apps.messaging',
        );
        expect(result, isNotNull);
        expect(result!.amount, 540.0);
        expect(result.payee, 'Zomato');
        expect(result.category, 'Food');
        expect(result.type, DetectedTransactionType.expense);
      });

      test('Parses genuine Bank SMS credit', () {
        final result = NotificationTrackingService.parseTransactionText(
          title: 'ICICI Bank',
          content:
              'Dear Customer, your a/c ending 4567 has been credited with INR 35,000.00 on 01-Oct-26.',
          packageName: 'com.google.android.apps.messaging',
        );
        expect(result, isNotNull);
        expect(result!.amount, 35000.0);
        expect(result.type, DetectedTransactionType.income);
      });
    });

    group('CategoryBudget & BudgetService Tests', () {
      test('Calculates category spending correctly with and without splits', () {
        final now = DateTime(2026, 10, 15);
        final txns = [
          Transaction(
            id: '1',
            amount: 500,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Food',
            date: DateTime(2026, 10, 2),
          ),
          Transaction(
            id: '2',
            amount: 300,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Other',
            splits: [
              TransactionSplit(category: 'Food', amount: 200),
              TransactionSplit(category: 'Shopping', amount: 100),
            ],
            date: DateTime(2026, 10, 5),
          ),
          Transaction(
            id: '3',
            amount: 400,
            type: TransactionType.income, // Income should not count towards expense budget
            sourceAccountId: 1,
            category: 'Food',
            date: DateTime(2026, 10, 10),
          ),
          Transaction(
            id: '4',
            amount: 600,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Food',
            date: DateTime(2026, 9, 28), // Previous month should be ignored
          ),
        ];

        final spent = BudgetService.calculateCategorySpent('Food', txns, now: now);
        expect(spent, 700.0); // 500 + 200
      });

      test('Computes BudgetStatus, burn rate, and alert flags properly', () {
        final now = DateTime(2026, 10, 15); // Day 15 of 31-day October -> 17 days remaining
        final budget = CategoryBudget(
          category: 'Dining',
          monthlyLimit: 10000,
          alertThreshold: 0.8,
        );

        final txns = [
          Transaction(
            id: '1',
            amount: 8500,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Dining',
            date: DateTime(2026, 10, 10),
          ),
        ];

        final status = BudgetService.getStatus(budget, txns, now: now);
        expect(status.spent, 8500.0);
        expect(status.remaining, 1500.0);
        expect(status.isNearLimit, isTrue); // 85% >= 80% threshold
        expect(status.isOverBudget, isFalse);
        expect(status.daysRemainingInMonth, 17);
        expect(status.dailyBurnRate.round(), (1500 / 17).round());
      });

      test('Flags over-budget condition accurately', () {
        final now = DateTime(2026, 10, 20);
        final budget = CategoryBudget(
          category: 'Shopping',
          monthlyLimit: 5000,
        );

        final txns = [
          Transaction(
            id: '1',
            amount: 5500,
            type: TransactionType.expense,
            sourceAccountId: 1,
            category: 'Shopping',
            date: DateTime(2026, 10, 12),
          ),
        ];

        final status = BudgetService.getStatus(budget, txns, now: now);
        expect(status.isOverBudget, isTrue);
        expect(status.remaining, 0.0);
      });
    });

    group('BillSubscription & SubscriptionBillsService Tests', () {
      test('Computes status: upcoming, due today, overdue, and paid', () {
        final now = DateTime(2026, 10, 12);

        final upcomingBill = BillSubscription(
          id: '1',
          name: 'Netflix',
          amount: 649,
          dueDate: DateTime(2026, 10, 15),
        );
        expect(upcomingBill.getStatus(now), BillStatus.upcoming);
        expect(upcomingBill.daysUntilDue, 3);

        final todayBill = BillSubscription(
          id: '2',
          name: 'WiFi',
          amount: 999,
          dueDate: DateTime(2026, 10, 12),
        );
        expect(todayBill.getStatus(now), BillStatus.dueToday);
        expect(todayBill.daysUntilDue, 0);

        final overdueBill = BillSubscription(
          id: '3',
          name: 'Rent',
          amount: 15000,
          dueDate: DateTime(2026, 10, 5),
        );
        expect(overdueBill.getStatus(now), BillStatus.overdue);

        final paidBill = BillSubscription(
          id: '4',
          name: 'Gym',
          amount: 1500,
          dueDate: DateTime(2026, 10, 8),
          lastPaidDate: DateTime(2026, 10, 7),
        );
        expect(paidBill.getStatus(now), BillStatus.paid);
      });

      test('Calculates monthly recurring commitment across frequencies', () {
        final bills = [
          BillSubscription(
            id: '1',
            name: 'Netflix',
            amount: 649, // Monthly
            frequency: RecurrenceFrequency.monthly,
            dueDate: DateTime(2026, 10, 15),
          ),
          BillSubscription(
            id: '2',
            name: 'Amazon Prime',
            amount: 1499, // Yearly -> ~124.91/mo
            frequency: RecurrenceFrequency.yearly,
            dueDate: DateTime(2026, 12, 1),
          ),
          BillSubscription(
            id: '3',
            name: 'House Help',
            amount: 500, // Weekly -> 500 * 4.33 = 2165/mo
            frequency: RecurrenceFrequency.weekly,
            dueDate: DateTime(2026, 10, 14),
          ),
        ];

        final total = SubscriptionBillsService.calculateTotalMonthlyCommitment(bills);
        final expected = 649.0 + (1499.0 / 12) + (500.0 * 4.33);
        expect((total - expected).abs() < 0.1, isTrue);
      });

      test('Advances next cycle due date accurately on monthly cycle', () {
        final bill = BillSubscription(
          id: '1',
          name: 'Rent',
          amount: 18000,
          frequency: RecurrenceFrequency.monthly,
          dueDate: DateTime(2026, 10, 15),
        );

        final nextDue = SubscriptionBillsService.calculateNextCycleDueDate(bill);
        expect(nextDue.year, 2026);
        expect(nextDue.month, 11);
        expect(nextDue.day, 15);
      });
    });
  });
}