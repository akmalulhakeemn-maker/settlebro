# SettleBro - Premium Dark Mode Group Expense Splitter

## Overview
SettleBro is a complete Flutter app for splitting group expenses with a premium dark-mode interface, teal accent color, and intelligent balance calculations.

## Architecture
**Single File Implementation:** All code is in `lib/main.dart` with:
- Data models (Member, Group, Expense, Split, Settlement)
- Business logic (BalanceCalculator)
- All 5 screens
- State management using `setState()`

## Color Scheme
- **Primary (Teal):** `#20D6B0`
- **Background:** `#0D1117`
- **Cards:** `#171C25`
- **Text Primary:** `#FFFFFF`
- **Text Secondary:** `#B0B7C3`

## Screens

### 1. Home Screen
- **Header:** Logo placeholder + app name + tagline "Settle fast. No drama."
- **Summary Card:** Shows aggregate "You owe" and "Owed to you" across all groups
- **Action Grid:** 6 quick actions (Add Expense, Settle Up, Remind, Export PDF, Auto Balance, Insights)
- **Active Groups List:** Shows all groups with outstanding amounts
- **Sample Data:** Pre-loaded with 2 sample groups (Dinner, Roommates)

### 2. Quick Split Screen
- **Total Amount Input:** Enter the total expense amount
- **Number of People Input:** Specify how many people are splitting
- **Live Calculation:** Amount per person updates in real-time
- **Currency Selector:** Default QAR, also supports USD, EUR, AED, SAR
- **Market Rates Section:** Placeholder for future exchange rate/market data integration

### 3. Groups Screen
- **Search Bar:** Filter groups by name
- **Create Group Button:** Add new groups with emoji selector
- **Group List Cards:** Shows member count, total expenses, and outstanding amounts
- **Navigation:** Tap a group to view group details

### 4. Settings Screen
- **Account Section:** Name, email, and sign-out button
- **Preferences:** Dark mode toggle, default currency (QAR), country (Qatar)
- **About Section:** App version, contact support, privacy policy, terms of service

### 5. Group Detail Screen
- **Summary Card:** Your balance in this group, total expenses, outstanding
- **Members List:** Shows each member's balance with status (owes/owed/settled)
- **Mark Paid Button:** Creates pending settlements for amounts owed
- **Expenses List:** Expandable view of all expenses with split details
- **Settlements List:** Shows payment history with pending/confirmed status
- **Add Expense FAB:** Float action button to add new expenses

## Data Models

### Member
```dart
- name: String
- email: String
```

### Group
```dart
- id: String (unique identifier)
- name: String
- emoji: String
- members: List<Member>
- expenses: List<Expense>
- settlements: List<Settlement>
```

### Expense
```dart
- id: String
- title: String
- amount: double
- paidBy: String (member name)
- splits: List<Split>
- createdAt: DateTime
- groupId: String (reference to group)
```

### Split
```dart
- memberName: String
- amount: double
```

### Settlement
```dart
- id: String
- from: String (who paid)
- to: String (who received)
- amount: double
- status: String (pending, paid_pending_confirmation, confirmed)
- createdAt: DateTime
```

## Calculation Logic

### Balance Calculation
1. **Expense Processing:**
   - Payer receives credit for the full expense amount
   - Each split participant is debited their split amount

2. **Settlement Processing:**
   - Only "confirmed" settlements update balances
   - Pending settlements are shown but don't affect balance calculations

3. **User Balance:**
   - Positive balance = "You are owed QAR X"
   - Negative balance = "You owe QAR X"
   - Zero balance = "All settled"

### Settlement Flow
1. User can "Mark Paid" when they owe someone
2. This creates a settlement with status "paid_pending_confirmation"
3. Settlement shows "Confirm" button
4. On confirmation, status becomes "confirmed" and affects balances
5. Confirmed settlements are visually indicated

### Split Types

**Equal Split:**
- Amount divided equally among all participants
- Each person's split = Total Amount / Number of Participants
- Payer does not owe themselves

**Custom Split:**
- User enters custom amount for each participant
- Validation ensures total custom splits equal expense amount
- Shows error if amounts don't match

## Features Implemented

✅ Local in-memory state (no Firebase/Supabase)
✅ Dark mode UI with teal accents
✅ Group management (create, view, search)
✅ Member management (add members to groups)
✅ Expense tracking (add expenses with descriptions)
✅ Equal and custom split support
✅ Settlement tracking with status (pending, paid_pending, confirmed)
✅ Intelligent balance calculations
✅ Group summary and outstanding calculation
✅ Clean, rounded fintech design
✅ Sample data pre-loaded
✅ Beginner-friendly code with comments

## Future Enhancements (Placeholders Ready)
- Firebase/Supabase integration
- User authentication
- Currency exchange rates API
- PDF export
- Auto-balance suggestions
- Expense analytics and insights
- Push notifications for reminders
- Dark mode preference storage

## How to Run

```bash
cd /Users/akmalulhakeem/settlebro_v2
flutter pub get
flutter run
```

## Code Organization
- **Lines 1-20:** Imports and Constants
- **Lines 21-185:** Data Models (Member, Split, Expense, Settlement, Group)
- **Lines 186-240:** Calculation Logic (BalanceCalculator)
- **Lines 241-270:** Main App Entry Point
- **Lines 271-450:** Home Screen
- **Lines 451-640:** Quick Split Screen
- **Lines 641-870:** Groups Screen
- **Lines 871-1070:** Settings Screen
- **Lines 1071-1740:** Group Detail Screen
- **Lines 1741-1980:** Add Expense Dialog

## Key Implementation Details

### State Management
Uses `setState()` for simplicity - suitable for the current scale. Each screen is a StatefulWidget that manages its own state.

### Data Persistence
Currently in-memory only. Groups list is maintained in the `_SettleBroHomeState` and passed between screens. To make it persistent:
1. Replace `setState()` with Provider, Riverpod, or BLoC
2. Add local database (Hive, Isar, or SQLite)
3. Save data to Firebase/Supabase

### Navigation
Uses Flutter's built-in `Navigator` with `MaterialPageRoute` for screen navigation. Bottom navigation bar controls the main tab switching.

### Design System
All colors, spacing, and styles use constants defined at the top for consistency and easy theming.
