import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:flutter_test/flutter_test.dart';
// REPLACE 'expense_tracker' with your actual package name from pubspec.yaml if different
import 'package:expense_tracker/main.dart';

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
          transactions: txns, accounts: accounts, byCategory: true);

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
          transactions: txns, accounts: accounts, byCategory: true);

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
          transactions: txns, accounts: accounts, byCategory: false);

      expect(breakdown['Bank'], 50.0);
      expect(breakdown['Wallet'], 30.0);
    });
  });
}