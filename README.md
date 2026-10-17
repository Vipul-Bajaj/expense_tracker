# Secure Expense Tracker

A powerful, secure, and feature-rich personal finance application built with Flutter. This app helps you track your income, expenses, and transfers across multiple accounts with enterprise-grade security and insightful analytics.

## 🌟 Unique Features

* **🔒 AES-256 Encryption**: Unlike standard trackers, this app encrypts your financial data (transaction amounts, account balances, notes) *before* it leaves your device or is stored locally. Your privacy is paramount.
* **🔐 Biometric Security**: Integrated `local_auth` support allows you to lock the app using Face ID or Fingerprint authentication.
* **🔄 Recurring Transactions**: Set it and forget it. Automatically handle daily, weekly, monthly, or yearly subscriptions and bills.
* **➗ Split Expenses**: Break down a single transaction into multiple categories (e.g., a supermarket bill split into "Groceries" and "Home Supplies").
* **💱 Live Currency Conversion**: Real-time currency conversion for viewing your financial health in INR, USD, or EUR, powered by live rate updates.

## 🚀 Key Features

* **Multi-Account Management**: Track Bank Accounts, Wallets, Credit Cards, and Cash separately.
* **Google Sign-In**: Seamless and secure authentication using Firebase Auth.
* **Comprehensive Dashboard**:
    * Monthly overview of Income vs. Expense.
    * Quick view of recent transactions.
    * Total Balance calculation.
* **Advanced Reporting**:
    * **Visual Charts**: Pie charts and Bar graphs for category breakdowns and monthly comparisons.
    * **CSV Export**: Export your financial data to CSV for external analysis.
* **Customizable Categories**: Create, edit, and manage categories and sub-categories to fit your spending habits.
* **Theme Support**: Fully responsive Light and Dark modes.

## 🛠️ Tech Stack

* **Framework**: [Flutter](https://flutter.dev/)
* **Backend**: [Firebase](https://firebase.google.com/) (Firestore, Auth)
* **Local Storage**: [Hive](https://docs.hivedb.dev/) (Settings, caching)
* **State Management**: Native Flutter (`setState`, `ValueNotifier`)
* **Encryption**: `encrypt` package (AES-256)
* **Charts**: Custom painters for high-performance visualization.

## 📱 Installation & Setup

### Prerequisites
* Flutter SDK (Version >=3.4.3)
* Dart SDK
* A Firebase Project

### Steps

1.  **Clone the Repository**
    ```bash
    git clone [https://github.com/vipul-bajaj/expense_tracker.git](https://github.com/vipul-bajaj/expense_tracker.git)
    cd expense_tracker
    ```

2.  **Firebase Configuration**
    * **Android**: Download `google-services.json` from your Firebase Console and place it in `android/app/`.
    * **iOS**: Download `GoogleService-Info.plist` and place it in `ios/Runner/`. **Note:** Ensure the `REVERSED_CLIENT_ID` in `Info.plist` matches your Google Service file.

3.  **Install Dependencies**
    ```bash
    flutter pub get
    ```

4.  **Run the App**
    ```bash
    flutter run
    ```

## 🚢 Release Build (Google Play)

Release builds must be signed with your upload key; the build fails if signing is not configured.

1.  **Create an upload key** (once — back it up somewhere safe, never commit it):
    ```bash
    keytool -genkey -v -keystore android/app/upload-keystore.jks \
      -keyalg RSA -keysize 2048 -validity 10000 -alias upload
    ```
2.  **Create `android/key.properties`** (git-ignored):
    ```properties
    storePassword=<keystore password>
    keyPassword=<key password>
    keyAlias=upload
    storeFile=upload-keystore.jks
    ```
3.  **Build the App Bundle:** `flutter build appbundle --release`
4.  **Firebase / Google Sign-In:** add the SHA-1 and SHA-256 of both your upload key and the
    Play App Signing key (Play Console → Test and release → App integrity) to the Android app in
    the Firebase console, then download the updated `google-services.json`.

**CI:** add these repository secrets so the workflow produces a Play-ready, signed `.aab`:
`UPLOAD_KEYSTORE_BASE64` (`base64 -w0 upload-keystore.jks`), `UPLOAD_KEYSTORE_PASSWORD`,
`UPLOAD_KEY_ALIAS`, `UPLOAD_KEY_PASSWORD`. Without them CI falls back to debug-signed test builds
(`ALLOW_DEBUG_RELEASE_SIGNING=true`), which Google Play will reject.

**Firestore rules** live in `firestore.rules`; deploy with `firebase deploy --only firestore:rules`.
The privacy policy and account deletion pages are in `web/` and are published with Firebase Hosting.

## 📖 How to Use

1.  **Dashboard**: View your current month's summary. Toggle months using the arrows.
2.  **Add Transaction**: Click the floating `+` button. Select Income/Expense/Transfer. Toggle "Split" for complex expenses or "Repeat" for recurring ones.
3.  **Accounts Tab**: Add your bank accounts or wallets here to establish opening balances.
4.  **Reports Tab**: Analyze spending habits. Toggle between Pie Chart and List view. Use the Download icon to export CSV.
5.  **Settings (Profile)**: Click your avatar on the Dashboard to toggle Biometric Lock, change Currency, or switch Themes.

## 🔒 Security Note

The application uses a hardcoded key in `lib/main.dart` for demonstration/encryption purposes. For a production release, it is recommended to manage keys using a secure keystore or dynamic key generation strategy.