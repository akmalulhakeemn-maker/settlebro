import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'revenue_cat_config.dart';

// ============================================================================
// CONSTANTS
// ============================================================================

const Color kPrimaryColor = Color(0xFF20D6B0); // Teal accent
const Color kTextPrimary = Color(0xFFFFFFFF); // White text
const Color kTextSecondary = Color(0xFFB0B7C3); // Gray text
const String kAppVersion = '1.0.2';
const String kTagline = 'Settle fast. No drama.';

/// Debug-only Firestore wipe for owned groups. Set to `true` temporarily while
/// clearing bad local/Firestore test data, then set back to `false`.
const bool kDevFirestoreResetOnLaunch = false;

/// Free uses of premium-gated home actions before the paywall (non-subscribers).
const int kPremiumTrialLimit = 3;
const String kPremiumTrialUsedKey = 'premium_trial_used_count';

Future<int> getPremiumTrialUsed() async {
  final p = await SharedPreferences.getInstance();
  return p.getInt(kPremiumTrialUsedKey) ?? 0;
}

Future<void> incrementPremiumTrialUsed() async {
  final p = await SharedPreferences.getInstance();
  final n = p.getInt(kPremiumTrialUsedKey) ?? 0;
  await p.setInt(kPremiumTrialUsedKey, n + 1);
}

/// Returns true if the action may proceed. Counts a trial use when not premium.
Future<bool> canUsePremiumFeatureOrShowPaywall(
  BuildContext context, {
  required bool isPremium,
  required VoidCallback onShowPremium,
}) async {
  if (isPremium) return true;
  final used = await getPremiumTrialUsed();
  if (used < kPremiumTrialLimit) {
    await incrementPremiumTrialUsed();
    final after = await getPremiumTrialUsed();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Premium trial used $after/$kPremiumTrialLimit'),
        ),
      );
    }
    return true;
  }
  if (context.mounted) {
    onShowPremium();
  }
  return false;
}

/// Premium-only features with no free trial (Insights).
Future<bool> requirePremiumOrShowPaywall(
  BuildContext context, {
  required bool isPremium,
  required VoidCallback onShowPremium,
}) async {
  if (isPremium) return true;
  if (context.mounted) onShowPremium();
  return false;
}

// Global variables will be updated from Firebase Auth
String currentUserName = 'Akmal Hakeem';
String currentUserEmail = 'hakeem3322@gmail.com';
String currentUserUid = ''; // Will be set from Firebase Auth
String currentCountry = 'Qatar';
String currentCurrency = 'QAR';

/// App-wide dark mode flag.
final ValueNotifier<bool> appDarkModeNotifier = ValueNotifier<bool>(true);

ThemeData settleBroDarkTheme() {
  const scaffold = Color(0xFF0D1117);
  const card = Color(0xFF171C25);
  final scheme = ColorScheme.dark(
    brightness: Brightness.dark,
    primary: kPrimaryColor,
    onPrimary: const Color(0xFF042521),
    secondary: const Color(0xFFFFC857),
    onSecondary: const Color(0xFF1C1404),
    tertiary: const Color(0xFFFF9800),
    onTertiary: const Color(0xFF1C1103),
    surface: card,
    onSurface: const Color(0xFFE6EDF3),
    onSurfaceVariant: kTextSecondary,
    error: const Color(0xFFFF6B6B),
    onError: const Color(0xFF1A0505),
    outline: const Color(0xFF29303B),
  );
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scaffold,
    cardColor: card,
    colorScheme: scheme,
    dividerColor: scheme.outline,
    textTheme: base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
  );
}

/// HTTPS invite URL for Universal Links (`https://settlebro.app/join?...`).
String buildGroupInviteHttpsLink(String groupId, String inviteCode) {
  return Uri(
    scheme: 'https',
    host: 'settlebro.app',
    path: '/join',
    queryParameters: <String, String>{
      'groupId': groupId,
      'code': inviteCode,
    },
  ).toString();
}

/// Primary invite URL stored on groups (HTTPS for production Universal Links).
String buildGroupInviteLink(String groupId, String inviteCode) {
  return buildGroupInviteHttpsLink(groupId, inviteCode);
}

/// Custom URL scheme fallback when Universal Links do not open the app.
String buildSettlebroSchemeInviteLink(String groupId, String inviteCode) {
  return 'settlebro://join?groupId=${Uri.encodeQueryComponent(groupId)}&code=${Uri.encodeQueryComponent(inviteCode)}';
}

/// Parses `https://settlebro.app/join?...` or `settlebro://join?...`.
({String groupId, String inviteCode})? parseJoinInviteUri(Uri uri) {
  final gid = uri.queryParameters['groupId'];
  final code = uri.queryParameters['code'];
  if (gid == null ||
      gid.isEmpty ||
      code == null ||
      code.isEmpty) {
    return null;
  }

  final schemeOk = uri.scheme == 'settlebro' && uri.host == 'join';
  final httpsOk = uri.scheme == 'https' &&
      (uri.host.toLowerCase() == 'settlebro.app' ||
          uri.host.toLowerCase() == 'www.settlebro.app') &&
      (uri.path == '/join' ||
          (uri.pathSegments.length == 1 && uri.pathSegments.first == 'join'));

  if (!schemeOk && !httpsOk) return null;
  return (groupId: gid, inviteCode: code);
}

/// Global [Navigator] for deep-link flows before a route owns context.
final GlobalKey<NavigatorState> settleBroNavigatorKey =
    GlobalKey<NavigatorState>();

/// Set by [SettleBroHome] so invite joins can merge into the group list.
void Function(Group group)? settleBroUpsertGroupFromInvite;

class PendingGroupInvite {
  static const _kGroupId = 'pending_join_group_id';
  static const _kCode = 'pending_join_invite_code';

  static Future<void> store(String groupId, String inviteCode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kGroupId, groupId);
    await p.setString(_kCode, inviteCode);
  }

  static Future<({String? groupId, String? inviteCode})> peek() async {
    final p = await SharedPreferences.getInstance();
    return (
      groupId: p.getString(_kGroupId),
      inviteCode: p.getString(_kCode),
    );
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kGroupId);
    await p.remove(_kCode);
  }
}

/// Serialized invite joins so cold-start + home resume never overlap.
Future<void> _joinInviteChain = Future<void>.value();

Future<void> runJoinInviteFlow(String groupId, String inviteCode) {
  _joinInviteChain = _joinInviteChain.then(
    (_) => _runJoinInviteFlowBody(groupId, inviteCode),
  );
  return _joinInviteChain;
}

Future<void> _runJoinInviteFlowBody(String groupId, String inviteCode) async {
  BuildContext? navCtx;
  for (var i = 0; i < 60; i++) {
    navCtx = settleBroNavigatorKey.currentContext;
    if (navCtx != null && navCtx.mounted) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  navCtx = settleBroNavigatorKey.currentContext;
  if (navCtx == null || !navCtx.mounted) return;

  final preview =
      await FirestoreService.getGroupByInvite(groupId, inviteCode);
  navCtx = settleBroNavigatorKey.currentContext;
  if (navCtx == null || !navCtx.mounted) return;

  if (preview == null) {
    ScaffoldMessenger.of(navCtx).showSnackBar(
      const SnackBar(content: Text('Invalid or expired invite')),
    );
    await PendingGroupInvite.clear();
    return;
  }

  if (FirestoreService.isCurrentUserMemberOf(preview)) {
    await PendingGroupInvite.clear();
    settleBroUpsertGroupFromInvite?.call(preview);
    navCtx = settleBroNavigatorKey.currentContext;
    if (navCtx == null || !navCtx.mounted) return;
    Navigator.of(navCtx).push(
      MaterialPageRoute<void>(
        builder: (context) => GroupDetailScreen(
          group: preview,
          onGroupUpdated: (g) => settleBroUpsertGroupFromInvite?.call(g),
        ),
      ),
    );
    return;
  }

  final accepted = await showDialog<bool>(
    context: navCtx,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: Theme.of(ctx).cardColor,
      title: Text('Join ${preview.name}?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Join'),
        ),
      ],
    ),
  );

  if (accepted != true) {
    await PendingGroupInvite.clear();
    return;
  }

  final joined =
      await FirestoreService.joinGroupViaVerifiedInvite(groupId, inviteCode);
  navCtx = settleBroNavigatorKey.currentContext;
  if (joined == null) {
    if (navCtx != null && navCtx.mounted) {
      ScaffoldMessenger.of(navCtx).showSnackBar(
        const SnackBar(content: Text('Invalid or expired invite')),
      );
    }
    await PendingGroupInvite.clear();
    return;
  }

  await PendingGroupInvite.clear();
  settleBroUpsertGroupFromInvite?.call(joined);
  navCtx = settleBroNavigatorKey.currentContext;
  if (navCtx == null || !navCtx.mounted) return;
  Navigator.of(navCtx).push(
    MaterialPageRoute<void>(
      builder: (context) => GroupDetailScreen(
        group: joined,
        onGroupUpdated: (g) => settleBroUpsertGroupFromInvite?.call(g),
      ),
    ),
  );
}

Future<void> handleIncomingJoinLink(Uri uri) async {
  final parsed = parseJoinInviteUri(uri);
  if (parsed == null) return;

  BuildContext? ctx;
  for (var i = 0; i < 60; i++) {
    ctx = settleBroNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  if (FirebaseAuth.instance.currentUser == null) {
    await PendingGroupInvite.store(parsed.groupId, parsed.inviteCode);
    ctx = settleBroNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('Sign in to join this group.')),
      );
    }
    return;
  }

  await runJoinInviteFlow(parsed.groupId, parsed.inviteCode);
}

/// Placeholder email when a member has no address (local-part from name).
String placeholderMemberEmail(String name) {
  final slug =
      name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return '${slug.isEmpty ? 'member' : slug}@example.com';
}

/// Opens WhatsApp with a prefilled invite message (user must send manually).
Future<void> shareGroupInvite(BuildContext context, Group group) async {
  final resolved = group.withResolvedInviteFields();
  final httpsUrl = buildGroupInviteHttpsLink(resolved.id, resolved.inviteCode);
  final schemeUrl =
      buildSettlebroSchemeInviteLink(resolved.id, resolved.inviteCode);
  final message = 'Join my SettleBro group: ${resolved.name}\n'
      '$httpsUrl\n'
      'If link does not open, copy this:\n'
      '$schemeUrl';

  final encodedMessage = Uri.encodeComponent(message);
  final whatsappUrl = Uri.parse('https://wa.me/?text=$encodedMessage');

  if (await canLaunchUrl(whatsappUrl)) {
    await launchUrl(whatsappUrl, mode: LaunchMode.externalApplication);
  } else {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp')),
      );
    }
  }
}

/// Premium prices by onboarding currency (extend map as needed).
/// Fallbacks when RevenueCat / App Store prices are unavailable (matches AS tier).
Map<String, double> premiumPricesForCurrency(String currency) {
  switch (currency.toUpperCase()) {
    case 'QAR':
    case 'SAR':
      return {'monthly': 9.99, 'yearly': 99.99};
    default:
      return {'monthly': 9.99, 'yearly': 99.99};
  }
}

/// Small crown badge for premium-locked actions (grid cells).
Widget premiumLockCornerBadge(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Positioned(
    top: 6,
    right: 6,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: cs.secondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        '👑',
        style: TextStyle(fontSize: 10),
      ),
    ),
  );
}

// ============================================================================
// FIRESTORE SERVICE - Handles all Firestore operations for Phase 1
// ============================================================================

class FirestoreService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get current Firebase user
  static User? getCurrentUser() => _auth.currentUser;

  /// Create a new group in Firestore
  /// groupData: Map with 'name', 'currency' (optional: 'createdByName')
  static Future<String> createGroup(Map<String, dynamic> groupData) async {
    try {
      final user = getCurrentUser();
      if (user == null) throw Exception('User not authenticated');

      final inviteCode =
          groupData['inviteCode'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString();
      final addDefaultMember = groupData['addDefaultMember'] as bool? ?? true;

      final docRef = await _db.collection('groups').add({
        'name': groupData['name'] ?? 'New Group',
        'currency': groupData['currency'] ?? 'USD',
        'emoji': groupData['emoji'] ?? '👥',
        'inviteCode': inviteCode,
        'createdByUid': user.uid,
        'createdByEmail': user.email,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final inviteLink = buildGroupInviteLink(docRef.id, inviteCode);
      await docRef.update({'inviteLink': inviteLink});

      if (addDefaultMember) {
        await _db
            .collection('groups')
            .doc(docRef.id)
            .collection('members')
            .add({
          'uid': user.uid,
          'name': user.displayName ?? user.email?.split('@')[0] ?? 'User',
          'email': user.email,
          'joinedAt': FieldValue.serverTimestamp(),
        });
      }

      return docRef.id;
    } catch (e) {
      rethrow;
    }
  }

  /// Get a single group with real-time updates via Stream
  static Stream<Group?> getGroupStream(String groupId) {
    return _db.collection('groups').doc(groupId).snapshots().asyncMap((
      doc,
    ) async {
      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      final members = await getGroupMembers(groupId);
      final expenses = await getGroupExpenses(groupId);
      final settlements = await getGroupSettlements(groupId);

      final inviteCode = data['inviteCode']?.toString() ?? '';
      final inviteLink = data['inviteLink']?.toString() ??
          (inviteCode.isNotEmpty
              ? buildGroupInviteLink(doc.id, inviteCode)
              : '');

      return Group(
        id: doc.id,
        name: data['name'] ?? 'Group',
        currency: data['currency']?.toString() ?? currentCurrency,
        emoji: data['emoji'] ?? '👥',
        members: members,
        expenses: expenses,
        settlements: settlements,
        inviteCode: inviteCode,
        inviteLink: inviteLink,
      );
    });
  }

  /// Get all groups for current user
  static Future<List<Group>> getUserGroups() async {
    try {
      final user = getCurrentUser();
      if (user == null) return [];

      final snapshot = await _db.collection('groups').get();
      final groups = <Group>[];

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final members = await getGroupMembers(doc.id);
        final expenses = await getGroupExpenses(doc.id);
        final settlements = await getGroupSettlements(doc.id);

        final inviteCode = data['inviteCode']?.toString() ?? '';
        final inviteLink = data['inviteLink']?.toString() ??
            (inviteCode.isNotEmpty
                ? buildGroupInviteLink(doc.id, inviteCode)
                : '');

        groups.add(
          Group(
            id: doc.id,
            name: data['name'] ?? 'Group',
            currency: data['currency']?.toString() ?? currentCurrency,
            emoji: data['emoji'] ?? '👥',
            members: members,
            expenses: expenses,
            settlements: settlements,
            inviteCode: inviteCode,
            inviteLink: inviteLink,
          ),
        );
      }

      return groups;
    } catch (e) {
      return [];
    }
  }

  /// Add member to group
  static Future<void> addMemberToGroup(
    String groupId,
    String memberName,
    String memberEmail, {
    String memberUid = '',
  }) async {
    try {
      await _db.collection('groups').doc(groupId).collection('members').add({
        'uid': memberUid,
        'name': memberName,
        'email': memberEmail,
        'joinedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Email used when joining via invite (fallback when auth email missing).
  static String joinMemberEmail() {
    final e = currentUserEmail.trim();
    if (e.isNotEmpty) return e;
    final uid = currentUserUid.trim();
    if (uid.isEmpty) return 'guest@example.com';
    return '$uid@join.settlebro.local';
  }

  static String joinMemberName() {
    final n = currentUserName.trim();
    if (n.isNotEmpty) return n;
    final uid = currentUserUid.trim();
    if (uid.length >= 8) return 'Member ${uid.substring(0, 8)}';
    return 'Member';
  }

  static bool membersContainEmail(List<Member> members, String email) {
    final lower = email.toLowerCase();
    return members.any((m) => m.email.toLowerCase() == lower);
  }

  /// True if the current user is already listed as a member (email or Firebase uid).
  static bool isCurrentUserMemberOf(Group group) {
    final email = joinMemberEmail();
    if (membersContainEmail(group.members, email)) return true;
    final uid = currentUserUid.trim();
    if (uid.isEmpty) return false;
    return group.members.any((m) => m.uid.isNotEmpty && m.uid == uid);
  }

  /// Verifies the group exists and [inviteCode] matches the Firestore document.
  static Future<Group?> getGroupByInvite(
    String groupId,
    String inviteCode,
  ) async {
    try {
      final doc = await _db.collection('groups').doc(groupId).get();
      if (!doc.exists) return null;
      final data = doc.data()!;
      final stored = data['inviteCode']?.toString() ?? '';
      if (stored != inviteCode) return null;
      return await fetchFullGroup(groupId);
    } catch (e) {
      return null;
    }
  }

  /// Loads a full [Group] snapshot (members, expenses, settlements).
  static Future<Group?> fetchFullGroup(String groupId) async {
    try {
      final doc = await _db.collection('groups').doc(groupId).get();
      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      final members = await getGroupMembers(groupId);
      final expenses = await getGroupExpenses(groupId);
      final settlements = await getGroupSettlements(groupId);

      final inviteCode = data['inviteCode']?.toString() ?? '';
      final inviteLink = data['inviteLink']?.toString() ??
          (inviteCode.isNotEmpty
              ? buildGroupInviteLink(doc.id, inviteCode)
              : '');

      return Group(
        id: doc.id,
        name: data['name'] ?? 'Group',
        currency: data['currency']?.toString() ?? currentCurrency,
        emoji: data['emoji'] ?? '👥',
        members: members,
        expenses: expenses,
        settlements: settlements,
        inviteCode: inviteCode,
        inviteLink: inviteLink,
      );
    } catch (e) {
      return null;
    }
  }

  /// Adds the current user as a member when invite is valid and they are new.
  /// Returns the updated group, or `null` if the invite is invalid.
  static Future<Group?> joinGroupViaVerifiedInvite(
    String groupId,
    String inviteCode,
  ) async {
    final verified = await getGroupByInvite(groupId, inviteCode);
    if (verified == null) return null;

    if (isCurrentUserMemberOf(verified)) {
      return verified;
    }

    await addMemberToGroup(
      groupId,
      joinMemberName(),
      joinMemberEmail(),
      memberUid: currentUserUid,
    );
    return await fetchFullGroup(groupId);
  }

  /// Get members of a group
  static Future<List<Member>> getGroupMembers(String groupId) async {
    try {
      final snapshot = await _db
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return Member(
          name: data['name'] ?? 'Unknown',
          email: data['email'] ?? '',
          uid: data['uid']?.toString() ?? '',
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  /// Create an expense in Firestore
  static Future<void> createExpense(
    String groupId,
    Expense expense, {
    required String currency,
  }) async {
    try {
      await _db.collection('groups').doc(groupId).collection('expenses').add({
        'title': expense.title,
        'amount': expense.amount,
        'currency': currency,
        'paidByName': expense.paidBy,
        'paidByEmail': currentUserEmail, // Get actual payer email from UI
        'paidByUid': currentUserUid,
        'splitWith': expense.splits
            .map((s) => {'member': s.memberName, 'amount': s.amount})
            .toList(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Get expenses for a group
  static Future<List<Expense>> getGroupExpenses(String groupId) async {
    try {
      final snapshot = await _db
          .collection('groups')
          .doc(groupId)
          .collection('expenses')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        final splits = List<Map<String, dynamic>>.from(data['splitWith'] ?? [])
            .map(
              (s) => Split(
                memberName: s['member'] ?? '',
                amount: s['amount'] ?? 0.0,
              ),
            )
            .toList();

        return Expense(
          id: doc.id,
          title: data['title'] ?? '',
          amount: (data['amount'] ?? 0.0).toDouble(),
          paidBy: data['paidByName'] ?? '',
          splits: splits,
          createdAt:
              (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
          groupId: groupId,
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  static Settlement settlementFromFirestoreDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw StateError('Settlement document has no data');
    }
    return Settlement(
      id: doc.id,
      from: data['payerName'] ?? '',
      to: data['receiverName'] ?? '',
      payerEmail: data['payerEmail'] ?? '',
      receiverEmail: data['receiverEmail'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      status: data['status'] ?? 'pending_confirmation',
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      relatedExpenseId: data['relatedExpenseId'] as String?,
    );
  }

  /// Creates a settlement or returns an existing pending one for the same payer/receiver (no error).
  static Future<({Settlement settlement, bool createdNew})> createSettlement(
    String groupId,
    Settlement settlement,
    String currency,
  ) async {
    final coll =
        _db.collection('groups').doc(groupId).collection('settlements');
    final existingSnap = await coll
        .where('payerEmail', isEqualTo: settlement.payerEmail)
        .where('receiverEmail', isEqualTo: settlement.receiverEmail)
        .get();

    for (final doc in existingSnap.docs) {
      final st = doc.data()['status'] as String? ?? '';
      if (st == 'paid_pending_confirmation' || st == 'pending_confirmation') {
        return (
          settlement: settlementFromFirestoreDoc(doc),
          createdNew: false,
        );
      }
    }

    final docRef = await coll.add({
      'payerUid': '',
      'payerEmail': settlement.payerEmail,
      'payerName': settlement.from,
      'receiverUid': '',
      'receiverEmail': settlement.receiverEmail,
      'receiverName': settlement.to,
      'amount': settlement.amount,
      'currency': currency,
      'status': settlement.status,
      'createdAt': FieldValue.serverTimestamp(),
      'paidAt': settlement.status == 'paid_pending_confirmation'
          ? FieldValue.serverTimestamp()
          : null,
      'confirmedAt': null,
    });

    final saved = await docRef.get();
    return (
      settlement: settlementFromFirestoreDoc(saved),
      createdNew: true,
    );
  }

  static Future<void> _deleteQueryDocuments(
    Query<Map<String, dynamic>> query,
  ) async {
    while (true) {
      final snap = await query.limit(400).get();
      if (snap.docs.isEmpty) break;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
  }

  /// Debug only: deletes all groups owned by [userId] and nested expenses/members/settlements.
  static Future<void> resetUserDataDevOnly(String userId) async {
    if (!kDebugMode || userId.isEmpty) return;

    final owned = await _db
        .collection('groups')
        .where('createdByUid', isEqualTo: userId)
        .get();

    for (final doc in owned.docs) {
      final base = doc.reference;
      await _deleteQueryDocuments(base.collection('members'));
      await _deleteQueryDocuments(base.collection('expenses'));
      await _deleteQueryDocuments(base.collection('settlements'));
      await base.delete();
    }
  }

  /// Update settlement status
  static Future<void> updateSettlementStatus(
    String groupId,
    String settlementId,
    String newStatus,
  ) async {
    try {
      final updateData = <String, dynamic>{'status': newStatus};

      if (newStatus == 'paid_pending_confirmation') {
        updateData['paidAt'] = FieldValue.serverTimestamp();
      } else if (newStatus == 'confirmed') {
        updateData['confirmedAt'] = FieldValue.serverTimestamp();
      }

      await _db
          .collection('groups')
          .doc(groupId)
          .collection('settlements')
          .doc(settlementId)
          .update(updateData);
    } catch (e) {
      rethrow;
    }
  }

  /// Get settlements for a group
  static Future<List<Settlement>> getGroupSettlements(String groupId) async {
    try {
      final snapshot = await _db
          .collection('groups')
          .doc(groupId)
          .collection('settlements')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return Settlement(
          id: doc.id,
          from: data['payerName'] ?? '',
          to: data['receiverName'] ?? '',
          payerEmail: data['payerEmail'] ?? '',
          receiverEmail: data['receiverEmail'] ?? '',
          amount: (data['amount'] ?? 0.0).toDouble(),
          status: data['status'] ?? 'pending_confirmation',
          createdAt:
              (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  /// Get a stream of settlements for real-time updates
  static Stream<List<Settlement>> getSettlementsStream(String groupId) {
    return _db
        .collection('groups')
        .doc(groupId)
        .collection('settlements')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return Settlement(
              id: doc.id,
              from: data['payerName'] ?? '',
              to: data['receiverName'] ?? '',
              payerEmail: data['payerEmail'] ?? '',
              receiverEmail: data['receiverEmail'] ?? '',
              amount: (data['amount'] ?? 0.0).toDouble(),
              status: data['status'] ?? 'pending_confirmation',
              createdAt:
                  (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
            );
          }).toList();
        });
  }
}

// ============================================================================
// DATA MODELS
// ============================================================================

class Member {
  final String name;
  final String email;
  /// Firebase Auth uid when the member joined from the app; empty for legacy rows.
  final String uid;

  Member({required this.name, required this.email, this.uid = ''});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Member && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;
}

class Split {
  final String memberName;
  final double amount;

  Split({required this.memberName, required this.amount});
}

class Expense {
  final String id;
  final String title;
  final double amount;
  final String paidBy;
  final List<Split> splits;
  final DateTime createdAt;
  final String groupId;

  Expense({
    required this.id,
    required this.title,
    required this.amount,
    required this.paidBy,
    required this.splits,
    required this.createdAt,
    required this.groupId,
  });
}

class Settlement {
  final String id;
  final String from; // debtor name
  final String to; // creditor name
  final String payerEmail; // debtor email
  final String receiverEmail; // creditor email
  final double amount;
  final String
  status; // pending_confirmation (not paid yet), paid_pending_confirmation (paid, waiting for receiver confirmation), confirmed (completed)
  final DateTime createdAt;
  final String? relatedExpenseId; // Link to the expense that created this debt

  Settlement({
    required this.id,
    required this.from,
    required this.to,
    required this.payerEmail,
    required this.receiverEmail,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.relatedExpenseId,
  });
}

class Group {
  final String id;
  final String name;
  final String currency;
  final String emoji;
  final List<Member> members;
  final List<Expense> expenses;
  final List<Settlement> settlements;
  final String inviteCode;
  final String inviteLink;

  Group({
    required this.id,
    required this.name,
    required this.currency,
    required this.emoji,
    required this.members,
    this.expenses = const [],
    this.settlements = const [],
    required this.inviteCode,
    required this.inviteLink,
  });

  Group copyWith({
    String? id,
    String? name,
    String? currency,
    String? emoji,
    List<Member>? members,
    List<Expense>? expenses,
    List<Settlement>? settlements,
    String? inviteCode,
    String? inviteLink,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      currency: currency ?? this.currency,
      emoji: emoji ?? this.emoji,
      members: members ?? this.members,
      expenses: expenses ?? this.expenses,
      settlements: settlements ?? this.settlements,
      inviteCode: inviteCode ?? this.inviteCode,
      inviteLink: inviteLink ?? this.inviteLink,
    );
  }

  /// Firestore-style map (nested lists not included; use for metadata/sync helpers).
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'currency': currency,
      'emoji': emoji,
      'inviteCode': inviteCode,
      'inviteLink': inviteLink,
    };
  }

  factory Group.fromMap(
    Map<String, dynamic> map, {
    List<Member> members = const [],
    List<Expense> expenses = const [],
    List<Settlement> settlements = const [],
  }) {
    final gid = map['id'] as String? ?? '';
    var code = map['inviteCode'] as String? ?? '';
    var link = map['inviteLink'] as String? ?? '';
    if (link.isEmpty && code.isNotEmpty && gid.isNotEmpty) {
      link = buildGroupInviteLink(gid, code);
    }
    return Group(
      id: gid,
      name: map['name'] as String? ?? 'Group',
      currency: map['currency'] as String? ?? currentCurrency,
      emoji: map['emoji'] as String? ?? '👥',
      members: members,
      expenses: expenses,
      settlements: settlements,
      inviteCode: code,
      inviteLink: link,
    );
  }

  /// Ensures [inviteCode] / [inviteLink] are safe for sharing (legacy groups).
  /// Uses [DateTime.now().millisecondsSinceEpoch] for code only when missing.
  /// Does not persist to Firestore — update UI by assigning the returned group.
  Group withResolvedInviteFields() {
    if (id.isEmpty) return this;
    final code = inviteCode.isNotEmpty
        ? inviteCode
        : DateTime.now().millisecondsSinceEpoch.toString();
    final link = inviteLink.isNotEmpty
        ? inviteLink
        : buildGroupInviteLink(id, code);
    if (code == inviteCode && link == inviteLink) return this;
    return copyWith(inviteCode: code, inviteLink: link);
  }
}

// ============================================================================
// CALCULATION LOGIC
// ============================================================================

class BalanceCalculator {
  static Map<String, double> calculateBalances(Group group) {
    final Map<String, double> balances = {};

    for (var member in group.members) {
      balances[member.name] = 0;
    }

    for (var expense in group.expenses) {
      balances[expense.paidBy] =
          (balances[expense.paidBy] ?? 0) + expense.amount;

      for (var split in expense.splits) {
        balances[split.memberName] =
            (balances[split.memberName] ?? 0) - split.amount;
      }
    }

    // IMPORTANT:
    // Confirmed settlement means debtor already paid creditor.
    // So debtor balance goes UP toward zero.
    // Creditor balance goes DOWN toward zero.
    for (var settlement in group.settlements) {
      if (settlement.status == 'confirmed') {
        balances[settlement.from] =
            (balances[settlement.from] ?? 0) + settlement.amount;

        balances[settlement.to] =
            (balances[settlement.to] ?? 0) - settlement.amount;
      }
    }

    balances.updateAll((key, value) => value.abs() < 0.01 ? 0 : value);
    return balances;
  }

  static bool hasPendingSettlement(
    Group group,
    String debtor,
    String creditor,
  ) {
    return group.settlements.any(
      (s) =>
          s.from == debtor &&
          s.to == creditor &&
          s.status == 'paid_pending_confirmation',
    );
  }

  static bool hasConfirmedSettlement(
    Group group,
    String debtor,
    String creditor,
  ) {
    return group.settlements.any(
      (s) => s.from == debtor && s.to == creditor && s.status == 'confirmed',
    );
  }

  static List<Settlement> generateSmartSettlements(Group group) {
    final balances = calculateBalances(group);
    const epsilon = 0.01;
    final debtors = <Map<String, dynamic>>[];
    final creditors = <Map<String, dynamic>>[];

    for (final member in group.members) {
      final balance = balances[member.name] ?? 0.0;
      if (balance < -epsilon) {
        debtors.add({'name': member.name, 'amount': balance.abs()});
      } else if (balance > epsilon) {
        creditors.add({'name': member.name, 'amount': balance});
      }
    }

    bool hasExistingSettlement(String from, String to) {
      return group.settlements.any(
        (s) =>
            s.from == from &&
            s.to == to &&
            (s.status == 'paid_pending_confirmation' || s.status == 'confirmed'),
      );
    }

    final suggestions = <Settlement>[];
    int debtorIndex = 0;
    int creditorIndex = 0;

    while (debtorIndex < debtors.length && creditorIndex < creditors.length) {
      final debtor = debtors[debtorIndex];
      final creditor = creditors[creditorIndex];
      final settleAmount = min(
        debtor['amount'] as double,
        creditor['amount'] as double,
      );

      if (settleAmount > epsilon &&
          !hasExistingSettlement(
            debtor['name'] as String,
            creditor['name'] as String,
          )) {
        suggestions.add(
          Settlement(
            id: 'smart_${DateTime.now().microsecondsSinceEpoch}_${suggestions.length}',
            from: debtor['name'] as String,
            to: creditor['name'] as String,
            payerEmail: '',
            receiverEmail: '',
            amount: settleAmount,
            status: 'pending',
            createdAt: DateTime.now(),
          ),
        );
      }

      debtor['amount'] = (debtor['amount'] as double) - settleAmount;
      creditor['amount'] = (creditor['amount'] as double) - settleAmount;

      if ((debtor['amount'] as double) <= epsilon) debtorIndex++;
      if ((creditor['amount'] as double) <= epsilon) creditorIndex++;
    }

    return suggestions;
  }

  static Map<String, dynamic> getUserSummary(Group group) {
    final balances = calculateBalances(group);
    final userBalance = balances['You'] ?? 0;

    if (userBalance > 0.01) {
      return {
        'type': 'owed',
        'amount': userBalance,
        'text':
            'You are owed ${group.currency} ${userBalance.toStringAsFixed(2)}',
      };
    } else if (userBalance < -0.01) {
      return {
        'type': 'owes',
        'amount': userBalance.abs(),
        'text':
            'You owe ${group.currency} ${userBalance.abs().toStringAsFixed(2)}',
      };
    } else {
      return {'type': 'settled', 'amount': 0.0, 'text': 'All settled'};
    }
  }

  static double getGroupOutstanding(Group group) {
    final balances = calculateBalances(group);
    return balances.values
        .where((b) => b < -0.01)
        .fold<double>(0, (sum, b) => sum + b.abs());
  }

  static double getTotalExpenses(Group group) {
    return group.expenses.fold<double>(0, (sum, exp) => sum + exp.amount);
  }
}

// ============================================================================
// UTILITY CLASSES & FUNCTIONS
// ============================================================================

class PdfGenerator {
  static Future<void> generateAndPrintExpenseReport(Group group) async {
    final pdf = pw.Document();
    final balances = BalanceCalculator.calculateBalances(group);
    final totalExpenses = BalanceCalculator.getTotalExpenses(group);

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(
                level: 0,
                child: pw.Text(
                  'SettleBro - ${group.name} ${group.emoji}',
                  style: pw.TextStyle(
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(height: 12),
              pw.Text(
                'Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(height: 20),
              pw.Header(
                level: 1,
                child: pw.Text(
                  'Summary',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Text(
                'Total Expenses: ${group.currency} ${totalExpenses.toStringAsFixed(2)}',
              ),
              pw.Text('Members: ${group.members.length}'),
              pw.SizedBox(height: 16),
              pw.Header(
                level: 1,
                child: pw.Text(
                  'Expenses',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Description',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Amount',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Paid By',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Date',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  ...group.expenses.map((expense) {
                    return pw.TableRow(
                      children: [
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(8),
                          child: pw.Text(expense.title),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(8),
                          child: pw.Text(
                            '${group.currency} ${expense.amount.toStringAsFixed(2)}',
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(8),
                          child: pw.Text(expense.paidBy),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(8),
                          child: pw.Text(
                            DateFormat('yyyy-MM-dd').format(expense.createdAt),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Header(
                level: 1,
                child: pw.Text(
                  'Balances',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              ...balances.entries.map((entry) {
                final name = entry.key;
                final balance = entry.value;
                String status = 'Settled';
                if (balance > 0) {
                  status =
                      'Is owed ${group.currency} ${balance.toStringAsFixed(2)}';
                } else if (balance < 0) {
                  status =
                      'Owes ${group.currency} ${balance.abs().toStringAsFixed(2)}';
                }
                return pw.Text(
                  '$name: $status',
                  style: const pw.TextStyle(fontSize: 12),
                );
              }).toList(),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }
}

class InsightsCalculator {
  static Map<String, dynamic> getGroupInsights(Group group) {
    final balances = BalanceCalculator.calculateBalances(group);
    final totalExpenses = BalanceCalculator.getTotalExpenses(group);

    // Single source of truth: aggregate spend by member from expenses.
    final spentByMember = <String, double>{};
    for (var expense in group.expenses) {
      spentByMember[expense.paidBy] =
          (spentByMember[expense.paidBy] ?? 0) + expense.amount;
    }

    final topSpender = spentByMember.isEmpty
        ? ''
        : spentByMember.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    final maxSpent = spentByMember.isEmpty
        ? 0
        : spentByMember.values.reduce((a, b) => a > b ? a : b);

    final positiveBalances =
        balances.entries.where((e) => e.value > 0.01).toList();
    final mostOwedEntry = positiveBalances.isEmpty
        ? null
        : positiveBalances
            .reduce((a, b) => a.value >= b.value ? a : b);
    final mostOwedUser = mostOwedEntry?.key ?? '';
    final mostOwedAmount = mostOwedEntry?.value ?? 0.0;

    return {
      'totalExpenses': totalExpenses,
      'topSpender': topSpender,
      'topSpenderAmount': maxSpent,
      'mostOwedUser': mostOwedUser,
      'mostOwedAmount': mostOwedAmount,
      'memberCount': group.members.length,
      'expenseCount': group.expenses.length,
    };
  }
}

class ReminderGenerator {
  static List<Map<String, dynamic>> getPendingReminders(Group group) {
    final balances = BalanceCalculator.calculateBalances(group);
    final reminders = <Map<String, dynamic>>[];

    // People who owe money
    balances.forEach((name, balance) {
      if (balance < 0 && name != 'You') {
        reminders.add({
          'type': 'unpaid',
          'member': name,
          'currency': group.currency,
          'amount': balance.abs(),
          'message':
              '$name owes ${group.currency} ${balance.abs().toStringAsFixed(2)}',
        });
      }
    });

    // People waiting for confirmation
    for (var settlement in group.settlements) {
      if (settlement.status == 'paid_pending_confirmation') {
        reminders.add({
          'type': 'paid_pending_confirmation',
          'member': settlement.from,
          'currency': group.currency,
          'amount': settlement.amount,
          'message':
              '${settlement.from} marked as paid - waiting for confirmation',
        });
      }
    }

    return reminders;
  }
}

// ============================================================================
// MAIN APP
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Firebase Auth and set current user info
  final firebaseUser = FirebaseAuth.instance.currentUser;
  if (firebaseUser != null) {
    currentUserUid = firebaseUser.uid;
    currentUserEmail = firebaseUser.email ?? 'user@example.com';
    currentUserName =
        firebaseUser.displayName ?? currentUserEmail.split('@')[0];
    if (kDevFirestoreResetOnLaunch) {
      await FirestoreService.resetUserDataDevOnly(currentUserUid);
    }
  }

  await configureRevenueCatForIos(
    appUserId: currentUserUid.isEmpty ? null : currentUserUid,
  );

  runApp(const SettleBroApp());
}

class SettleBroApp extends StatefulWidget {
  const SettleBroApp({Key? key}) : super(key: key);

  @override
  State<SettleBroApp> createState() => _SettleBroAppState();
}

class _SettleBroAppState extends State<SettleBroApp> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _initAppLinks();
  }

  Future<void> _initAppLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        debugPrint('Deep link received: $initial');
        await handleIncomingJoinLink(initial);
      }
    } catch (_) {}

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) {
        debugPrint('Deep link received: $uri');
        handleIncomingJoinLink(uri);
      },
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: settleBroNavigatorKey,
      title: 'SettleBro',
      theme: settleBroDarkTheme(),
      darkTheme: settleBroDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const OnboardingScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class CountryOption {
  final String name;
  final String flag;
  final String currency;

  CountryOption({
    required this.name,
    required this.flag,
    required this.currency,
  });
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool isLoginMode = false;
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  CountryOption? selectedCountry;

  final List<CountryOption> countries = [
    CountryOption(name: 'Qatar', flag: '🇶🇦', currency: 'QAR'),
    CountryOption(name: 'UAE', flag: '🇦🇪', currency: 'AED'),
    CountryOption(name: 'Saudi Arabia', flag: '🇸🇦', currency: 'SAR'),
    CountryOption(name: 'Oman', flag: '🇴🇲', currency: 'OMR'),
    CountryOption(name: 'Kuwait', flag: '🇰🇼', currency: 'KWD'),
    CountryOption(name: 'Bahrain', flag: '🇧🇭', currency: 'BHD'),
    CountryOption(name: 'Malaysia', flag: '🇲🇾', currency: 'MYR'),
  ];

  void _nextPage() {
    if (_currentPage == 1 && selectedCountry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select your country')),
      );
      return;
    }

    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _finishOnboarding();
    }
  }

  Future<void> _finishOnboarding() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    // Validation
    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields')),
      );
      return;
    }

    // Login Mode
    if (isLoginMode) {
      try {
        final credential = await FirebaseAuth.instance
            .signInWithEmailAndPassword(email: email, password: password);

        currentUserUid = credential.user!.uid;
        currentUserEmail = credential.user!.email ?? email;
        currentUserName = credential.user!.displayName ?? email.split('@')[0];

        if (selectedCountry != null) {
          currentCountry = selectedCountry!.name;
          currentCurrency = selectedCountry!.currency;
        }

        await revenueCatLogInIfNeeded(currentUserUid);

        if (!context.mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const SettleBroHome()),
        );
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-not-found') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No account found. Create a new account.'),
            ),
          );
        } else if (e.code == 'wrong-password') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incorrect password. Try again.')),
          );
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Login error: ${e.message}')));
        }
      }
      return;
    }

    // Create Account Mode
    final name = nameController.text.trim();
    final confirm = confirmPasswordController.text;

    if (name.isEmpty || confirm.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields')),
      );
      return;
    }

    if (password != confirm) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
      return;
    }

    if (selectedCountry != null) {
      currentCountry = selectedCountry!.name;
      currentCurrency = selectedCountry!.currency;
    }

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      currentUserUid = credential.user!.uid;
      currentUserEmail = credential.user!.email ?? email;
      currentUserName = name;

      await credential.user!.updateDisplayName(name);

      await revenueCatLogInIfNeeded(currentUserUid);

      if (!context.mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SettleBroHome()),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        setState(() {
          isLoginMode = true;
          nameController.clear();
          confirmPasswordController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account already exists. Please log in.'),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Account error: ${e.message}')));
      }
      return;
    }
  }

  Widget _pageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (index) {
        final active = index == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? kPrimaryColor : kTextSecondary.withOpacity(0.4),
            borderRadius: BorderRadius.circular(20),
          ),
        );
      }),
    );
  }

  Widget _logo() {
    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        color: kPrimaryColor,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: kPrimaryColor.withOpacity(0.3),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.asset(
          'assets/images/settlebro_logo.png',
          width: 92,
          height: 92,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _welcomePage() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _logo(),
          const SizedBox(height: 34),
          const Text(
            'Welcome to\nSettleBro',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.bold,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Split bills, track balances, and settle faster with your group.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kTextSecondary, fontSize: 16, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _countryPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose your country',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'We will map your country with the correct currency.',
            style: TextStyle(color: kTextSecondary, fontSize: 14),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView.builder(
              itemCount: countries.length,
              itemBuilder: (context, index) {
                final country = countries[index];
                final isSelected = selectedCountry?.name == country.name;

                return GestureDetector(
                  onTap: () => setState(() => selectedCountry = country),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isSelected
                            ? kPrimaryColor
                            : kTextSecondary.withOpacity(0.15),
                        width: isSelected ? 1.6 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          country.flag,
                          style: const TextStyle(fontSize: 32),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            country.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(
                            country.currency,
                            style: const TextStyle(
                              color: kPrimaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountPage() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 34),
            Text(
              isLoginMode ? 'Welcome back' : 'Create your account',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isLoginMode
                  ? 'Log in to your SettleBro account.'
                  : 'Use email and password to keep your group identity clear.',
              style: const TextStyle(color: kTextSecondary, fontSize: 14),
            ),
            const SizedBox(height: 28),
            // Name field - only shown in Create Account mode
            if (!isLoginMode) ...[
              _inputField(
                controller: nameController,
                label: 'Name',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 16),
            ],
            _inputField(
              controller: emailController,
              label: 'Email',
              icon: Icons.email_outlined,
            ),
            const SizedBox(height: 16),
            _inputField(
              controller: passwordController,
              label: 'Password',
              icon: Icons.lock_outline,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            // Confirm Password field - only shown in Create Account mode
            if (!isLoginMode) ...[
              _inputField(
                controller: confirmPasswordController,
                label: 'Confirm Password',
                icon: Icons.lock_reset,
                obscureText: true,
              ),
              const SizedBox(height: 24),
            ] else
              const SizedBox(height: 8),
            if (selectedCountry != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kPrimaryColor.withOpacity(0.25)),
                ),
                child: Text(
                  '${selectedCountry!.flag} ${selectedCountry!.name} selected • Currency: ${selectedCountry!.currency}',
                  style: const TextStyle(color: kTextSecondary),
                ),
              ),
            const SizedBox(height: 24),
            // Toggle Login/Create Account
            Center(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    isLoginMode = !isLoginMode;
                    nameController.clear();
                    emailController.clear();
                    passwordController.clear();
                    confirmPasswordController.clear();
                  });
                },
                child: Text(
                  isLoginMode
                      ? 'New to SettleBro? Create account'
                      : 'Already have an account? Log in',
                  style: const TextStyle(
                    color: kPrimaryColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: kPrimaryColor),
        filled: true,
        fillColor: Theme.of(context).cardColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: kTextSecondary.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: kPrimaryColor),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentPage = index),
                children: [_welcomePage(), _countryPage(), _accountPage()],
              ),
            ),
            _pageIndicator(),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryColor,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _nextPage,
                  child: Text(
                    _currentPage == 2
                        ? (isLoginMode ? 'Log In' : 'Create Account')
                        : 'Continue',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// HOME SCREEN
// ============================================================================

class SettleBroHome extends StatefulWidget {
  const SettleBroHome({Key? key}) : super(key: key);

  @override
  State<SettleBroHome> createState() => _SettleBroHomeState();
}

class _SettleBroHomeState extends State<SettleBroHome> {
  int _currentIndex = 0;
  bool isPremium = false;
  // Sample data - will be maintained across navigation
  late List<Group> groups;
  CustomerInfoUpdateListener? _revenueCatCustomerListener;

  @override
  void initState() {
    super.initState();
    _initializeSampleData();

    settleBroUpsertGroupFromInvite = (Group g) {
      if (!mounted) return;
      setState(() {
        final i = groups.indexWhere((x) => x.id == g.id);
        if (i >= 0) {
          groups[i] = g;
        } else {
          groups.add(g);
        }
      });
    };

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await PendingGroupInvite.peek();
      final gid = pending.groupId;
      final code = pending.inviteCode;
      if (gid != null &&
          code != null &&
          gid.isNotEmpty &&
          code.isNotEmpty &&
          FirebaseAuth.instance.currentUser != null) {
        await runJoinInviteFlow(gid, code);
      }
    });
    if (revenueCatPlatformSupported) {
      _revenueCatCustomerListener = (CustomerInfo info) {
        if (!mounted) return;
        final active = customerInfoHasPremium(info);
        if (active != isPremium) {
          setState(() => isPremium = active);
        }
      };
      Purchases.addCustomerInfoUpdateListener(_revenueCatCustomerListener!);
    }
    _refreshPremiumFromRevenueCat();
  }

  @override
  void dispose() {
    settleBroUpsertGroupFromInvite = null;
    final listener = _revenueCatCustomerListener;
    if (listener != null) {
      Purchases.removeCustomerInfoUpdateListener(listener);
    }
    super.dispose();
  }

  Future<void> _refreshPremiumFromRevenueCat() async {
    if (!revenueCatPlatformSupported) return;
    try {
      final info = await Purchases.getCustomerInfo();
      if (!mounted) return;
      setState(() => isPremium = customerInfoHasPremium(info));
    } catch (_) {}
  }

  void _initializeSampleData() {
    groups = [];
  }

  void _onNavigationTap(int index) {
    // Pop any pushed pages (like GroupDetail) when switching tabs
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }

    setState(() {
      _currentIndex = index;
    });
  }

  Future<void> _addGroup(
    Group group, {
    bool offerWhatsAppInviteAfter = false,
    String? currencyOverride,
  }) async {
    if (!isPremium && groups.length >= 3) {
      if (mounted) {
        _showPremiumPricing();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Free plan is limited to 3 groups. Upgrade for unlimited groups.',
            ),
          ),
        );
      }
      return;
    }
    try {
      final currency = currencyOverride ?? group.currency;
      final inviteCode = group.inviteCode.isNotEmpty
          ? group.inviteCode
          : DateTime.now().millisecondsSinceEpoch.toString();
      final multiMemberOrExpenses =
          group.members.length > 1 || group.expenses.isNotEmpty;

      final groupId = await FirestoreService.createGroup({
        'name': group.name,
        'currency': currency,
        'emoji': group.emoji,
        'inviteCode': inviteCode,
        'addDefaultMember': !multiMemberOrExpenses,
      });

      final inviteLink = buildGroupInviteLink(groupId, inviteCode);

      if (multiMemberOrExpenses) {
        for (final m in group.members) {
          await FirestoreService.addMemberToGroup(
            groupId,
            m.name,
            m.email.isNotEmpty ? m.email : placeholderMemberEmail(m.name),
          );
        }
      }

      for (final e in group.expenses) {
        await FirestoreService.createExpense(
          groupId,
          Expense(
            id: e.id,
            title: e.title,
            amount: e.amount,
            paidBy: e.paidBy,
            splits: e.splits,
            createdAt: e.createdAt,
            groupId: groupId,
          ),
          currency: currency,
        );
      }

      final savedGroup = group.copyWith(
        id: groupId,
        currency: currency,
        inviteCode: inviteCode,
        inviteLink: inviteLink,
        expenses: group.expenses
            .map(
              (e) => Expense(
                id: e.id,
                title: e.title,
                amount: e.amount,
                paidBy: e.paidBy,
                splits: e.splits,
                createdAt: e.createdAt,
                groupId: groupId,
              ),
            )
            .toList(),
      );

      setState(() {
        groups.add(savedGroup);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Group created. Share invite with your friends.',
            ),
            action: SnackBarAction(
              label: 'Share Invite',
              onPressed: () {
                shareGroupInvite(context, savedGroup);
              },
            ),
          ),
        );
      }

      _openGroupDetail(savedGroup);

      if (offerWhatsAppInviteAfter && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final share = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Theme.of(ctx).cardColor,
              title: const Text('Share invite?'),
              content: const Text(
                'Send your group invite on WhatsApp now?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Later'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(
                    'Share on WhatsApp',
                    style: TextStyle(color: kPrimaryColor),
                  ),
                ),
              ],
            ),
          );
          if (share == true && mounted) {
            await shareGroupInvite(context, savedGroup);
          }
        });
      }

      debugPrint('Group created with Firebase ID: $groupId');
    } catch (e) {
      debugPrint('Create group failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create group: $e')),
        );
      }
    }
  }

  void _openGroupDetail(Group group) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupDetailScreen(
          group: group,
          onGroupUpdated: (updatedGroup) {
            setState(() {
              final index = groups.indexWhere((g) => g.id == updatedGroup.id);
              if (index >= 0) {
                groups[index] = updatedGroup;
              }
            });
          },
        ),
      ),
    );
  }

  void _showPremiumPricing() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PremiumPricingScreen(
          onPremiumActivated: () {
            _refreshPremiumFromRevenueCat();
          },
        ),
      ),
    ).then((_) => _refreshPremiumFromRevenueCat());
  }

  Widget _buildScreen() {
    switch (_currentIndex) {
      case 0:
        return HomeScreen(
          groups: groups,
          onOpenGroup: _openGroupDetail,
          isPremium: isPremium,
          onShowPremium: _showPremiumPricing,
          onOpenSettings: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  isPremium: isPremium,
                  onShowPremium: _showPremiumPricing,
                ),
              ),
            );
          },
        );
      case 1:
        return QuickSplitScreen(
          groupsCount: groups.length,
          isPremium: isPremium,
          onShowPremium: _showPremiumPricing,
          onCommitQuickSplitGroup: (group, {String? currency}) =>
              _addGroup(
                group,
                offerWhatsAppInviteAfter: true,
                currencyOverride: currency,
              ),
        );
      case 2:
        return GroupsScreen(
          groups: groups,
          onGroupAdded: _addGroup,
          onOpenGroup: _openGroupDetail,
          isPremium: isPremium,
          onShowPremium: _showPremiumPricing,
        );
      case 3:
        return SettingsScreen(
          isPremium: isPremium,
          onShowPremium: _showPremiumPricing,
        );
      default:
        return HomeScreen(
          groups: groups,
          onOpenGroup: _openGroupDetail,
          isPremium: isPremium,
          onShowPremium: _showPremiumPricing,
          onOpenSettings: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  isPremium: isPremium,
                  onShowPremium: _showPremiumPricing,
                ),
              ),
            );
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onNavigationTap,
        backgroundColor: Theme.of(context).cardColor,
        selectedItemColor: kPrimaryColor,
        unselectedItemColor: kTextSecondary,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.calculate), label: 'Split'),
          BottomNavigationBarItem(icon: Icon(Icons.group), label: 'Groups'),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// HOME SCREEN IMPLEMENTATION
// ============================================================================

class HomeScreen extends StatefulWidget {
  final List<Group> groups;
  final Function(Group) onOpenGroup;
  final bool isPremium;
  final VoidCallback onShowPremium;
  final VoidCallback onOpenSettings;

  const HomeScreen({
    Key? key,
    required this.groups,
    required this.onOpenGroup,
    required this.isPremium,
    required this.onShowPremium,
    required this.onOpenSettings,
  }) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Expense> expenses = [];
  @override
  Widget build(BuildContext context) {
    final allGroups = widget.groups;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              'assets/images/settlebro_logo.png',
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'SettleBro',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      kTagline,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.notifications_outlined),
                      onPressed: () {},
                      color: kTextSecondary,
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: widget.onOpenSettings,
                      color: kTextSecondary,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Summary card
            if (allGroups.isNotEmpty)
              _buildSummaryCard(allGroups)
            else
              const Text('No groups yet. Create one to get started.'),
            const SizedBox(height: 20),

            // Quick actions grid
            _buildActionGrid(),
            const SizedBox(height: 20),

            // Active groups section
            Text(
              'Active Groups',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (allGroups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No groups yet',
                  style: TextStyle(color: kTextSecondary),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: allGroups.length,
                itemBuilder: (context, index) {
                  return _buildGroupCard(allGroups[index]);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(List<Group> groups) {
    // Aggregate balances across all groups
    double totalOwed = 0;
    double totalOwes = 0;

    for (var group in groups) {
      final summary = BalanceCalculator.getUserSummary(group);
      if (summary['type'] == 'owed') {
        totalOwed += summary['amount'] as double;
      } else if (summary['type'] == 'owes') {
        totalOwes += summary['amount'] as double;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimaryColor.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'You owe',
                    style: const TextStyle(color: kTextSecondary, fontSize: 12),
                  ),
                  Text(
                    '$currentCurrency ${totalOwes.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Owed to you',
                    style: const TextStyle(color: kTextSecondary, fontSize: 12),
                  ),
                  Text(
                    '$currentCurrency ${totalOwed.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: kPrimaryColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: kTextSecondary, height: 1),
          const SizedBox(height: 12),
          const Text(
            'View detailed balances in your groups',
            style: TextStyle(color: kTextSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildActionGrid() {
    final actions = [
      {'label': 'Add Expense', 'icon': Icons.add_circle_outline},
      {'label': 'Settle Up', 'icon': Icons.payment},
      {'label': 'Remind', 'icon': Icons.notifications},
      {'label': 'Export PDF', 'icon': Icons.download},
      {'label': 'Auto Balance', 'icon': Icons.balance},
      {'label': 'Insights', 'icon': Icons.bar_chart},
    ];

    const premiumLabels = {
      'Export PDF',
      'Auto Balance',
      'Insights',
      'Remind',
    };

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1,
      children: List.generate(actions.length, (index) {
        final action = actions[index];
        final label = action['label'] as String;
        final locked = !widget.isPremium && premiumLabels.contains(label);
        return _buildActionButton(
          label,
          action['icon'] as IconData,
          locked: locked,
        );
      }),
    );
  }

  Widget _buildActionButton(String label, IconData icon, {required bool locked}) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimaryColor.withOpacity(0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _handleActionButtonTap(label),
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: kPrimaryColor, size: 28),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (locked) premiumLockCornerBadge(context),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleActionButtonTap(String action) async {
    switch (action) {
      case 'Add Expense':
        if (widget.groups.isNotEmpty) {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Theme.of(context).cardColor,
            builder: (context) => AddExpenseDialog(
              group: widget.groups.first,
              onExpenseAdded: (expense) {
                if (!mounted) return;
                setState(() {
                  final updatedGroup = widget.groups.first.copyWith(
                    expenses: [...widget.groups.first.expenses, expense],
                  );
                  widget.groups[0] = updatedGroup;
                  widget.onOpenGroup(updatedGroup);
                });
                Navigator.pop(context);
              },
            ),
          );
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Create a group first')));
        }
        break;
      case 'Settle Up':
        showSettleUpModal(context, widget.groups);
        break;
      case 'Remind':
        if (!await canUsePremiumFeatureOrShowPaywall(
              context,
              isPremium: widget.isPremium,
              onShowPremium: widget.onShowPremium,
            ) ||
            !mounted) {
          return;
        }
        showRemindModal(
          context,
          widget.groups,
          isPremium: widget.isPremium,
          premiumFeatureAllowed: true,
          onShowPremium: widget.onShowPremium,
        );
        break;
      case 'Export PDF':
        if (!await canUsePremiumFeatureOrShowPaywall(
              context,
              isPremium: widget.isPremium,
              onShowPremium: widget.onShowPremium,
            ) ||
            !mounted) {
          return;
        }
        if (widget.groups.isNotEmpty) {
          showExportPdfModal(
            context,
            widget.groups.first,
            isPremium: widget.isPremium,
            premiumFeatureAllowed: true,
            onShowPremium: widget.onShowPremium,
          );
        }
        break;
      case 'Auto Balance':
        if (!await canUsePremiumFeatureOrShowPaywall(
              context,
              isPremium: widget.isPremium,
              onShowPremium: widget.onShowPremium,
            ) ||
            !mounted) {
          return;
        }
        showAutoBalanceModal(
          context,
          widget.groups,
          (updatedGroup) {
            setState(() {
              final index =
                  widget.groups.indexWhere((g) => g.id == updatedGroup.id);
              if (index >= 0) {
                widget.groups[index] = updatedGroup;
              }
            });
          },
          isPremium: widget.isPremium,
          premiumFeatureAllowed: true,
          onShowPremium: widget.onShowPremium,
        );
        break;
      case 'Insights':
        if (!await requirePremiumOrShowPaywall(
              context,
              isPremium: widget.isPremium,
              onShowPremium: widget.onShowPremium,
            ) ||
            !mounted) {
          return;
        }
        showInsightsModal(
          context,
          widget.groups,
          isPremium: widget.isPremium,
          premiumFeatureAllowed: true,
          onShowPremium: widget.onShowPremium,
        );
        break;
    }
  }

  Widget _buildGroupCard(Group group) {
    final outstanding = BalanceCalculator.getGroupOutstanding(group);
    final totalExpenses = BalanceCalculator.getTotalExpenses(group);
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => widget.onOpenGroup(group),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimaryColor.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Text(group.emoji, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      Text(
                        '${group.members.length} members',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        '${group.currency} ${totalExpenses.toStringAsFixed(0)}',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (outstanding > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${group.currency} ${outstanding.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.error,
                    ),
                  ),
                  Text(
                    'Outstanding',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// QUICK SPLIT SCREEN
// ============================================================================

class QuickSplitScreen extends StatefulWidget {
  final Future<void> Function(Group group, {String? currency})
      onCommitQuickSplitGroup;
  final int groupsCount;
  final bool isPremium;
  final VoidCallback onShowPremium;

  const QuickSplitScreen({
    Key? key,
    required this.onCommitQuickSplitGroup,
    required this.groupsCount,
    required this.isPremium,
    required this.onShowPremium,
  }) : super(key: key);

  @override
  State<QuickSplitScreen> createState() => _QuickSplitScreenState();
}

class _QuickSplitScreenState extends State<QuickSplitScreen> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _peopleController = TextEditingController();
  String _selectedCurrency = currentCurrency;

  @override
  void dispose() {
    _amountController.dispose();
    _peopleController.dispose();
    super.dispose();
  }

  double get _amountPerPerson {
    final amount = double.tryParse(_amountController.text) ?? 0;
    final people = int.tryParse(_peopleController.text) ?? 1;
    if (people <= 0) return 0;
    return amount / people;
  }

  Future<void> _createGroupFromQuickSplit() async {
    if (widget.groupsCount >= 3 && !widget.isPremium) {
      widget.onShowPremium();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Upgrade to Premium to create unlimited groups.'),
          ),
        );
      }
      return;
    }

    final total = double.tryParse(_amountController.text);
    final people = int.tryParse(_peopleController.text);
    if (total == null || total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid total amount')),
      );
      return;
    }
    if (people == null || people < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter number of people (at least 1)')),
      );
      return;
    }

    final nameController = TextEditingController();
    var submitted = false;
    try {
      submitted =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Theme.of(ctx).cardColor,
              title: const Text('Group name'),
              content: TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'e.g. Weekend trip',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: Theme.of(ctx).scaffoldBackgroundColor,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(
                    'Create',
                    style: TextStyle(color: kPrimaryColor),
                  ),
                ),
              ],
            ),
          ) ??
          false;

      if (!submitted || !mounted) return;

      final groupName = nameController.text.trim();
      if (groupName.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a group name')),
        );
        return;
      }

      final inviteCode = DateTime.now().millisecondsSinceEpoch.toString();
      final members = <Member>[
        Member(name: 'You', email: currentUserEmail),
        for (var i = 2; i <= people; i++)
          Member(
            name: 'Person $i',
            email: placeholderMemberEmail('Person $i'),
          ),
      ];

      final shareEach = total / people;
      final splits = members
          .map((m) => Split(memberName: m.name, amount: shareEach))
          .toList();

      final expense = Expense(
        id: '',
        title: 'Quick Split',
        amount: total,
        paidBy: 'You',
        splits: splits,
        createdAt: DateTime.now(),
        groupId: '',
      );

      final group = Group(
        id: '',
        name: groupName,
        currency: _selectedCurrency,
        emoji: '⚡',
        members: members,
        expenses: [expense],
        inviteCode: inviteCode,
        inviteLink: '',
      );

      await widget.onCommitQuickSplitGroup(group, currency: _selectedCurrency);
    } finally {
      nameController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Quick Split',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),

            // Total amount input
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Total Amount',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '0.00',
                    prefixText: '$_selectedCurrency ',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kPrimaryColor),
                    ),
                    filled: true,
                    fillColor: theme.cardColor,
                  ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Number of people input
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Number of People',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _peopleController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '1',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kPrimaryColor),
                    ),
                    filled: true,
                    fillColor: theme.cardColor,
                  ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Currency selector
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Currency',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    border: Border.all(color: kPrimaryColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButton<String>(
                    value:
                        [
                          'QAR',
                          'AED',
                          'SAR',
                          'OMR',
                          'KWD',
                          'BHD',
                          'MYR',
                        ].contains(_selectedCurrency)
                        ? _selectedCurrency
                        : 'QAR',
                    isExpanded: true,
                    underline: const SizedBox(),
                    dropdownColor: theme.cardColor,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedCurrency = value);
                      }
                    },
                    items: ['QAR', 'AED', 'SAR', 'OMR', 'KWD', 'BHD', 'MYR']
                        .map(
                          (currency) => DropdownMenuItem<String>(
                            value: currency,
                            child: Text(currency),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),

            // Result card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kPrimaryColor.withOpacity(0.5)),
              ),
              child: Column(
                children: [
                  const Text(
                    'Amount per person',
                    style: TextStyle(color: kTextSecondary, fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$_selectedCurrency ${_amountPerPerson.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: kPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: kTextSecondary),
                  const SizedBox(height: 16),
                  Text(
                    'Splitting $_selectedCurrency ${_amountController.text} between ${_peopleController.text} people',
                    style: const TextStyle(color: kTextSecondary, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _createGroupFromQuickSplit,
                icon: const Icon(Icons.group_add, color: kPrimaryColor),
                label: const Text(
                  'Create Group from Quick Split',
                  style: TextStyle(color: kPrimaryColor),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: kPrimaryColor),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// GROUPS SCREEN
// ============================================================================

class GroupsScreen extends StatefulWidget {
  final List<Group> groups;
  final Future<void> Function(Group) onGroupAdded;
  final Function(Group) onOpenGroup;
  final bool isPremium;
  final VoidCallback onShowPremium;

  const GroupsScreen({
    Key? key,
    required this.groups,
    required this.onGroupAdded,
    required this.onOpenGroup,
    required this.isPremium,
    required this.onShowPremium,
  }) : super(key: key);

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  final TextEditingController _searchController = TextEditingController();
  late List<Group> _filteredGroups;

  @override
  void initState() {
    super.initState();
    _filteredGroups = widget.groups;
  }

  @override
  void didUpdateWidget(covariant GroupsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _filteredGroups = widget.groups;
  }

  void _filterGroups(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredGroups = widget.groups;
      } else {
        _filteredGroups = widget.groups
            .where(
              (group) => group.name.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();
      }
    });
  }

  void _attemptCreateGroup() {
    if (widget.groups.length >= 3 && !widget.isPremium) {
      widget.onShowPremium();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Upgrade to Premium to create unlimited groups.'),
        ),
      );
      return;
    }
    _showCreateGroupDialog();
  }

  void _showCreateGroupDialog() {
    final nameController = TextEditingController();
    final emojiController = TextEditingController(text: '👥');

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Theme.of(dialogCtx).cardColor,
        title: const Text('Create New Group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                hintText: 'Group name',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(dialogCtx).scaffoldBackgroundColor,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emojiController,
              decoration: InputDecoration(
                hintText: 'Emoji',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(dialogCtx).scaffoldBackgroundColor,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                final inviteCode =
                    DateTime.now().millisecondsSinceEpoch.toString();
                final newGroup = Group(
                  id: '',
                  name: nameController.text,
                  currency: currentCurrency,
                  emoji: emojiController.text.isNotEmpty
                      ? emojiController.text
                      : '👥',
                  members: [
                    Member(name: 'You', email: currentUserEmail),
                  ],
                  inviteCode: inviteCode,
                  inviteLink: '',
                );
                Navigator.pop(dialogCtx);
                await widget.onGroupAdded(newGroup);
              }
            },
            child: const Text('Create', style: TextStyle(color: kPrimaryColor)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header with search
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Groups',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: _filterGroups,
                        decoration: InputDecoration(
                          hintText: 'Search groups...',
                          prefixIcon: const Icon(
                            Icons.search,
                            color: kTextSecondary,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: Theme.of(context).cardColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FloatingActionButton.small(
                      backgroundColor: kPrimaryColor,
                      onPressed: _attemptCreateGroup,
                      child: Icon(
                        Icons.add,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Groups list
          Expanded(
            child: _filteredGroups.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.group_outlined,
                          size: 48,
                          color: kTextSecondary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.groups.isEmpty
                              ? 'No groups yet. Create one to get started.'
                              : 'No groups found',
                          style: const TextStyle(color: kTextSecondary),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _attemptCreateGroup,
                          child: const Text(
                            'Create first group',
                            style: TextStyle(color: kPrimaryColor),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredGroups.length,
                    itemBuilder: (context, index) {
                      return _buildGroupListCard(_filteredGroups[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupListCard(Group group) {
    final outstanding = BalanceCalculator.getGroupOutstanding(group);
    final totalExpenses = BalanceCalculator.getTotalExpenses(group);
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => widget.onOpenGroup(group),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimaryColor.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(group.emoji, style: const TextStyle(fontSize: 32)),
                    const SizedBox(width: 12),
                    Text(
                      group.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (outstanding > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.error.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${group.currency} ${outstanding.toStringAsFixed(0)}',
                      style: TextStyle(
                        color: scheme.error,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${group.members.length} members',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(
                  'Total: ${group.currency} ${totalExpenses.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// LEGAL / POLICY SCREENS (in-app, App Store–ready)
// ============================================================================

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({Key? key}) : super(key: key);

  static TextStyle _bodyStyle(BuildContext context) => TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 15,
        height: 1.45,
      );

  static TextStyle _headingStyle(BuildContext context) => TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Privacy Policy'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Effective date: 3 May 2026',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'This Privacy Policy describes how SettleBro handles information when you use our app.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Information we collect', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'We collect and store information you provide or that is needed to run the service, including: your account email and display name; your country and currency preference; group names; member names and related details you add to groups; expenses and splits; settlements; and group invite links or invite codes you generate or use.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('How we use your information', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'We use this information to provide bill splitting, group expense tracking, reminders, exports (such as PDF), premium subscription access, and related features you choose to use in SettleBro.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Data sharing', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'We do not sell your personal data.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Third-party services', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'SettleBro relies on service providers to operate the app, including: Firebase (authentication and cloud data storage), RevenueCat (subscription management), and the Apple App Store and Google Play for app distribution and in-app purchases. We may use email and support tools to respond when you contact us.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Your choices', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'You may delete your account (where available in the app), adjust certain preferences in Settings, or contact us with questions or requests regarding your information.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Contact', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'Questions about this policy: support@settlebro.app',
              style: _bodyStyle(context),
            ),
          ],
        ),
      ),
    );
  }
}

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({Key? key}) : super(key: key);

  static TextStyle _bodyStyle(BuildContext context) => TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 15,
        height: 1.45,
      );

  static TextStyle _headingStyle(BuildContext context) => TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Terms of Service'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Effective date: 3 May 2026',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Welcome to SettleBro. By using the app, you agree to these terms.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('About the service', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'SettleBro helps you track and split shared expenses with others. You are responsible for the accuracy of the expenses, balances, and settlements you enter or confirm.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Payments', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'SettleBro does not process bank transfers or move money between users. Any payments happen outside the app between you and other parties.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Subscriptions', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'Premium subscriptions are billed and managed through the Apple App Store, Google Play, and/or RevenueCat according to their terms and your store account settings.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Acceptable use', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'You agree not to misuse the service, including fraud, harassment, illegal activity, or attempts to harm the app, other users, or third parties.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Changes and availability', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'We may modify features or these terms. The service may be unavailable at times for maintenance or reasons beyond our control.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Limitation of liability', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'To the fullest extent permitted by law, SettleBro and its operators are not liable for indirect or consequential damages arising from your use of the app. The app is provided “as is” without warranties of any kind, except where prohibited by law.',
              style: _bodyStyle(context),
            ),
            const SizedBox(height: 16),
            Text('Contact', style: _headingStyle(context)),
            const SizedBox(height: 8),
            Text(
              'Questions: support@settlebro.app',
              style: _bodyStyle(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// SETTINGS SCREEN
// ============================================================================

class SettingsScreen extends StatefulWidget {
  final bool isPremium;
  final VoidCallback onShowPremium;

  const SettingsScreen({
    Key? key,
    required this.isPremium,
    required this.onShowPremium,
  }) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _selectedCurrency;
  late String _selectedCountry;

  @override
  void initState() {
    super.initState();
    _selectedCurrency = currentCurrency;
    _selectedCountry = currentCountry;
  }

  void _openPremiumPricing() {
    widget.onShowPremium();
  }

  Future<void> _contactSupport() async {
    debugPrint('Opening support email');
    final emailUri = Uri.parse(
      'mailto:support@settlebro.app?subject=SettleBro%20Support',
    );

    try {
      if (!await canLaunchUrl(emailUri)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please email support@settlebro.app'),
            ),
          );
        }
        return;
      }
      final launched = await launchUrl(
        emailUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please email support@settlebro.app'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please email support@settlebro.app'),
          ),
        );
      }
    }
  }

  void _openPrivacyPolicy() {
    debugPrint('Opening in-app Privacy Policy');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PrivacyPolicyScreen(),
      ),
    );
  }

  void _openTermsOfService() {
    debugPrint('Opening in-app Terms of Service');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TermsOfServiceScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _premiumUpgradeCard(),
            ),
            const SizedBox(height: 28),
            // Padding wrapper for content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Account section
                  _settingsSectionLabel('ACCOUNT'),
                  const SizedBox(height: 12),
                  _accountCard(),
                  const SizedBox(height: 28),

                  // Preferences section
                  _settingsSectionLabel('PREFERENCES'),
                  const SizedBox(height: 12),
                  _preferenceCard(),
                  const SizedBox(height: 28),

                  // About section
                  _settingsSectionLabel('ABOUT'),
                  const SizedBox(height: 12),
                  _aboutCard(),
                  const SizedBox(height: 28),

                  // Danger zone section
                  _settingsSectionLabel('DANGER ZONE'),
                  const SizedBox(height: 12),
                  _dangerZoneCard(),
                  const SizedBox(height: 120), // Padding for bottom nav
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _premiumUpgradeCard() {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    const sub = kTextSecondary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: kPrimaryColor.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('👑', style: TextStyle(fontSize: 30)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'SettleBro Premium',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Unlock Export PDF, Auto Balance, Insights, Unlimited Groups, Remind Hub, and WhatsApp reminders.',
            style: TextStyle(color: sub, fontSize: 13),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimaryColor,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              onPressed: _openPremiumPricing,
              child: const Text('View Premium Plans'),
            ),
          ),
        ],
      ),
    );
  }

  /// Header with logo, app name, and action buttons
  Widget _buildHeader() {
    return Container(
      color: Theme.of(context).cardColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: kPrimaryColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/images/settlebro_logo.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'SettleBro',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                kTagline,
                style: const TextStyle(color: kTextSecondary, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () {},
                color: kTextSecondary,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () {},
                color: kTextSecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Section label (ACCOUNT, PREFERENCES, etc.)
  Widget _settingsSectionLabel(String label) {
    const muted = Color(0xFF8B949E);
    return Text(
      label,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: muted,
        letterSpacing: 2.0,
      ),
    );
  }

  /// Account card with avatar, name, email, and sign out
  Widget _accountCard() {
    final outline = Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outline, width: 1),
      ),
      child: Column(
        children: [
          // Avatar and name/email
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: kPrimaryColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Center(
                  child: Text(
                    'A',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: kPrimaryColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentUserName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    currentUserEmail,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF8B949E),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Sign out button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {},
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.logout, color: Color(0xFFEF4444), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Sign Out',
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showCountryPicker() {
    final countries = [
      {'country': 'Qatar', 'currency': 'QAR'},
      {'country': 'UAE', 'currency': 'AED'},
      {'country': 'Saudi Arabia', 'currency': 'SAR'},
      {'country': 'Oman', 'currency': 'OMR'},
      {'country': 'Kuwait', 'currency': 'KWD'},
      {'country': 'Bahrain', 'currency': 'BHD'},
      {'country': 'Malaysia', 'currency': 'MYR'},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: countries.map((item) {
              final isSelected = _selectedCountry == item['country'];

              return ListTile(
                title: Text(item['country']!),
                subtitle: Text(item['currency']!),
                trailing: isSelected
                    ? const Icon(Icons.check, color: kPrimaryColor)
                    : null,
                onTap: () {
                  setState(() {
                    _selectedCountry = item['country']!;
                    _selectedCurrency = item['currency']!;
                    currentCountry = item['country']!;
                    currentCurrency = item['currency']!;
                  });

                  Navigator.pop(context);

                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const SettleBroHome()),
                  );
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  /// Preference card with dark mode, currency, and country
  Widget _preferenceCard() {
    final outline = Theme.of(context).colorScheme.outline;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outline, width: 1),
      ),
      child: Column(
        children: [
          _settingsRow(
            icon: Icons.workspace_premium_outlined,
            label: 'Your plan',
            trailing: Text(
              widget.isPremium ? 'Premium Active' : 'Free Plan',
              style: const TextStyle(
                color: kPrimaryColor,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
          _divider(),
          // Dark Mode row
          _settingsRow(
            icon: Icons.dark_mode,
            label: 'Dark Mode',
            trailing: Switch(
              value: true,
              onChanged: null,
              activeThumbColor: kPrimaryColor,
              activeTrackColor: kPrimaryColor.withValues(alpha: 0.35),
            ),
          ),
          _divider(),
          // Default Currency row
          _settingsRow(
            icon: Icons.language,
            label: 'Default Currency',
            trailing: _pillValue(_selectedCurrency),
          ),
          _divider(),
          // Country row
          _settingsRow(
            icon: Icons.location_on,
            label: 'Country',
            trailing: GestureDetector(
              onTap: _showCountryPicker,
              child: _pillValue(_selectedCountry),
            ),
          ),
        ],
      ),
    );
  }

  /// About card with version, support, policies, etc.
  Widget _aboutCard() {
    final outline = Theme.of(context).colorScheme.outline;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outline, width: 1),
      ),
      child: Column(
        children: [
          // App Version row
          _settingsRow(
            icon: Icons.info,
            label: 'App Version',
            trailing: Text(
              kAppVersion,
              style: const TextStyle(fontSize: 16, color: Color(0xFF8B949E)),
            ),
          ),
          _divider(),
          // Contact Support row
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _contactSupport,
              child: _settingsRow(
                icon: Icons.mail_outline,
                label: 'Contact Support',
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF8B949E),
                ),
              ),
            ),
          ),
          _divider(),
          // Privacy Policy row
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openPrivacyPolicy,
              child: _settingsRow(
                icon: Icons.shield_outlined,
                label: 'Privacy Policy',
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF8B949E),
                ),
              ),
            ),
          ),
          _divider(),
          // Terms of Service row
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openTermsOfService,
              child: _settingsRow(
                icon: Icons.description_outlined,
                label: 'Terms of Service',
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF8B949E),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Danger zone card with delete account
  Widget _dangerZoneCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.delete_forever,
                  color: Color(0xFFEF4444),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Delete Account',
                  style: const TextStyle(
                    color: Color(0xFFEF4444),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Individual settings row with icon, label, and trailing widget
  Widget _settingsRow({
    required IconData icon,
    required String label,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: kPrimaryColor, size: 20),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          trailing,
        ],
      ),
    );
  }

  /// Pill-shaped value button (for currency, country)
  Widget _pillValue(String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: kPrimaryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kPrimaryColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, color: kPrimaryColor, size: 16),
        ],
      ),
    );
  }

  /// Thin divider between rows
  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Divider(height: 1, color: Theme.of(context).dividerColor),
    );
  }
}

class PremiumPricingScreen extends StatefulWidget {
  /// Called when RevenueCat reports entitlement [kPremiumEntitlementId] active.
  final VoidCallback? onPremiumActivated;

  const PremiumPricingScreen({Key? key, this.onPremiumActivated}) : super(key: key);

  @override
  State<PremiumPricingScreen> createState() => _PremiumPricingScreenState();
}

class _PremiumPricingScreenState extends State<PremiumPricingScreen> {
  String selectedPlan = 'yearly';
  bool _loadingOfferings = true;
  bool _purchaseBusy = false;
  String? _offeringsHint;
  Package? _monthlyPackage;
  Package? _yearlyPackage;

  @override
  void initState() {
    super.initState();
    _loadOfferings();
  }

  Future<void> _loadOfferings() async {
    if (!revenueCatPlatformSupported) {
      setState(() {
        _loadingOfferings = false;
        _offeringsHint =
            'In-app subscriptions use the App Store on iPhone.';
      });
      return;
    }
    try {
      final offerings = await Purchases.getOfferings();
      final pkgs = offerings.current?.availablePackages ?? [];
      setState(() {
        _monthlyPackage = packageForPlan(pkgs, yearly: false);
        _yearlyPackage = packageForPlan(pkgs, yearly: true);
        _loadingOfferings = false;
        if (_monthlyPackage == null && _yearlyPackage == null) {
          _offeringsHint =
              'No packages yet. In RevenueCat, attach products '
              '$kPremiumMonthlyProductId and $kPremiumYearlyProductId to the current offering.';
        }
      });
    } catch (_) {
      setState(() {
        _loadingOfferings = false;
        _offeringsHint = 'Could not load App Store prices. Pull to retry from Settings.';
      });
    }
  }

  String _fallbackMonthlyPrice() {
    final prices = premiumPricesForCurrency(currentCurrency);
    return '$currentCurrency ${prices['monthly']!.toStringAsFixed(2)}';
  }

  String _fallbackYearlyPrice() {
    final prices = premiumPricesForCurrency(currentCurrency);
    return '$currentCurrency ${prices['yearly']!.toStringAsFixed(2)}';
  }

  /// Second line on yearly plan (monthly equivalent billed annually).
  String _yearlyBilledMonthlyLine() {
    final pkg = _yearlyPackage;
    if (pkg != null) {
      try {
        final sp = pkg.storeProduct;
        final yearlyAmount = sp.price;
        final monthlyEq = yearlyAmount / 12.0;
        final code = sp.currencyCode;
        return '$code ${monthlyEq.toStringAsFixed(2)}/month billed yearly';
      } catch (_) {}
    }
    final cur = currentCurrency;
    final yAnnual = premiumPricesForCurrency(cur)['yearly']!;
    final m = yAnnual / 12.0;
    return '$cur ${m.toStringAsFixed(2)}/month billed yearly';
  }

  String _monthlyPriceLabel() =>
      _monthlyPackage?.storeProduct.priceString ?? _fallbackMonthlyPrice();

  String _yearlyPriceLabel() =>
      _yearlyPackage?.storeProduct.priceString ?? _fallbackYearlyPrice();

  Package? get _selectedPackage =>
      selectedPlan == 'yearly' ? _yearlyPackage : _monthlyPackage;

  Future<void> _restorePurchases() async {
    if (!revenueCatPlatformSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restore purchases is available on iOS.')),
      );
      return;
    }
    setState(() => _purchaseBusy = true);
    try {
      final info = await Purchases.restorePurchases();
      if (!mounted) return;
      if (customerInfoHasPremium(info)) {
        widget.onPremiumActivated?.call();
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Purchases restored. Premium is active.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No active subscription found for this Apple ID.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _purchaseBusy = false);
    }
  }

  Future<void> _subscribe() async {
    if (!revenueCatPlatformSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _offeringsHint ?? 'Subscriptions are not available on this device.',
          ),
        ),
      );
      return;
    }
    final pkg = _selectedPackage;
    if (pkg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'App Store product is not ready yet. Please try again later.',
          ),
        ),
      );
      return;
    }
    setState(() => _purchaseBusy = true);
    try {
      final result =
          await Purchases.purchase(PurchaseParams.package(pkg));
      if (!mounted) return;
      if (customerInfoHasPremium(result.customerInfo)) {
        widget.onPremiumActivated?.call();
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Welcome to SettleBro Premium!')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Purchase recorded. Premium may take a moment to activate.',
            ),
          ),
        );
      }
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code != PurchasesErrorCode.purchaseCancelledError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Purchase failed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Purchase failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _purchaseBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = cs.onSurface;
    final subtitleColor =
        isDark ? const Color(0xFFC9D1D9) : Colors.black54;
    final yearlySelected = selectedPlan == 'yearly';
    final monthlySelected = selectedPlan == 'monthly';

    final cardBg = theme.cardColor;
    final selectedCardTint = isDark
        ? const Color(0xFF1A332E)
        : kPrimaryColor.withValues(alpha: 0.12);
    final mutedBorder = cs.outline;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: kPrimaryColor),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(height: 12),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: kPrimaryColor.withOpacity(0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: kPrimaryColor.withOpacity(0.12),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('👑', style: TextStyle(fontSize: 44)),
                    const SizedBox(height: 14),
                    Text(
                      'Upgrade to\nSettleBro Premium',
                      style: TextStyle(
                        fontSize: 31,
                        fontWeight: FontWeight.bold,
                        height: 1.12,
                        color: primaryText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Export PDF, Auto Balance, Insights, Unlimited Groups, Remind Hub, and WhatsApp reminders.',
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              if (_offeringsHint != null) ...[
                Text(
                  _offeringsHint!,
                  style: TextStyle(color: subtitleColor, fontSize: 12, height: 1.35),
                ),
                const SizedBox(height: 14),
              ],

              if (_loadingOfferings)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: CircularProgressIndicator(color: kPrimaryColor),
                  ),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _planCard(
                        context,
                        title: 'Monthly',
                        priceDisplay: _monthlyPriceLabel(),
                        period: '/month',
                        subtitle: 'Flexible plan',
                        selected: monthlySelected,
                        badge: null,
                        secondaryPriceLine: null,
                        cardBg: cardBg,
                        selectedTint: selectedCardTint,
                        mutedBorder: mutedBorder,
                        primaryText: primaryText,
                        subtitleColor: subtitleColor,
                        onTap: () => setState(() => selectedPlan = 'monthly'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _planCard(
                        context,
                        title: 'Yearly',
                        priceDisplay: _yearlyPriceLabel(),
                        period: '/year',
                        subtitle: 'Billed annually',
                        selected: yearlySelected,
                        badge: 'Best Value',
                        secondaryPriceLine: _yearlyBilledMonthlyLine(),
                        cardBg: cardBg,
                        selectedTint: selectedCardTint,
                        mutedBorder: mutedBorder,
                        primaryText: primaryText,
                        subtitleColor: subtitleColor,
                        onTap: () => setState(() => selectedPlan = 'yearly'),
                      ),
                    ),
                  ],
                ),

              if (!_loadingOfferings &&
                  (_monthlyPackage == null || _yearlyPackage == null)) ...[
                const SizedBox(height: 12),
                Text(
                  'Estimated — App Store price loads when products are linked.',
                  style: TextStyle(color: subtitleColor, fontSize: 11, height: 1.35),
                ),
              ],

              const SizedBox(height: 14),
              Text(
                'Popular with sports groups and shared households.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: subtitleColor,
                  fontSize: 13,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),

              const SizedBox(height: 22),

              Text(
                'What you unlock',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 12),

              _featureTile(
                context,
                Icons.picture_as_pdf_outlined,
                'Export PDF',
                'Download group reports and summaries.',
              ),
              _featureTile(
                context,
                Icons.balance_outlined,
                'Auto Balance',
                'Fix rounding differences automatically.',
              ),
              _featureTile(
                context,
                Icons.bar_chart_outlined,
                'Insights',
                'See spending patterns, top spender and balances.',
              ),
              _featureTile(
                context,
                Icons.groups_outlined,
                'Unlimited Groups',
                'Free plan allows only 3 groups. Premium removes the limit.',
              ),
              _featureTile(
                context,
                Icons.notifications_active_outlined,
                'Remind Hub',
                'See what needs attention across groups.',
              ),
              _featureTile(
                context,
                Icons.chat_outlined,
                'WhatsApp reminders',
                'Send WhatsApp payment nudges from Remind and Auto Balance.',
              ),

              const SizedBox(height: 22),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryColor,
                    foregroundColor: Colors.black87,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: (_purchaseBusy || _loadingOfferings) ? null : _subscribe,
                  child: _purchaseBusy
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black87,
                          ),
                        )
                      : Text(
                          selectedPlan == 'yearly'
                              ? 'Upgrade Yearly'
                              : 'Start Premium',
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 10),

              Center(
                child: TextButton(
                  onPressed: (_purchaseBusy || _loadingOfferings)
                      ? null
                      : _restorePurchases,
                  child: Text(
                    'Restore Purchases',
                    style: TextStyle(
                      color: primaryText.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 4),

              Center(
                child: Text(
                  'Cancel anytime. No hidden fees.',
                  style: TextStyle(color: subtitleColor, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _planCard(
    BuildContext context, {
    required String title,
    required String priceDisplay,
    required String period,
    required String subtitle,
    required bool selected,
    required String? badge,
    String? secondaryPriceLine,
    required Color cardBg,
    required Color selectedTint,
    required Color mutedBorder,
    required Color primaryText,
    required Color subtitleColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: selected ? selectedTint : cardBg,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected ? kPrimaryColor : mutedBorder,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: primaryText,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: TextStyle(color: subtitleColor, fontSize: 12),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        priceDisplay,
                        style: const TextStyle(
                          color: kPrimaryColor,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4, left: 4),
                      child: Text(
                        period,
                        style: TextStyle(
                          color: subtitleColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                if (secondaryPriceLine != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      secondaryPriceLine,
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? kPrimaryColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kPrimaryColor),
                  ),
                  child: Text(
                    selected ? 'Selected' : 'Choose',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected ? Colors.black87 : kPrimaryColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (badge != null)
            Positioned(
              top: -12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC857),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _featureTile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final theme = Theme.of(context);
    final primaryText = theme.colorScheme.onSurface;
    final subtitleColor = theme.brightness == Brightness.dark
        ? kTextSecondary
        : Colors.black54;
    final outline = theme.colorScheme.outline;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: outline),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: kPrimaryColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: kPrimaryColor, size: 22),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: primaryText,
                    fontWeight: FontWeight.bold,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.check_circle, color: kPrimaryColor, size: 20),
        ],
      ),
    );
  }
}
// ============================================================================
// GROUP DETAIL SCREEN
// ============================================================================

class GroupDetailScreen extends StatefulWidget {
  final Group? group;
  final Function(Group) onGroupUpdated;

  const GroupDetailScreen({
    Key? key,
    required this.group,
    required this.onGroupUpdated,
  }) : super(key: key);

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late Group _group;
  final String currentUser = 'You';

  @override
  void initState() {
    super.initState();
    final base = widget.group ??
        Group(
          id: '0',
          name: 'Sample Group',
          currency: currentCurrency,
          emoji: '👥',
          members: [],
          inviteCode: 'sample-local',
          inviteLink: buildGroupInviteLink('0', 'sample-local'),
        );
    _group = base.withResolvedInviteFields();
  }

  void _addExpense() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      builder: (context) => AddExpenseDialog(
        group: _group,
        onExpenseAdded: (expense) {
          if (!mounted) return;
          setState(() {
            _group = _group.copyWith(expenses: [..._group.expenses, expense]);
          });
          widget.onGroupUpdated(_group);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _addMember() {
    final nameController = TextEditingController();
    final emailController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Theme.of(dialogCtx).cardColor,
        title: const Text('Add Member'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                hintText: 'Member name',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Theme.of(dialogCtx).scaffoldBackgroundColor,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'Email (optional)',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Theme.of(dialogCtx).scaffoldBackgroundColor,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              final rawEmail = emailController.text.trim();
              final email = rawEmail.isEmpty
                  ? placeholderMemberEmail(name)
                  : rawEmail;

              final newMember = Member(name: name, email: email);

              if (!_group.members.any((m) => m.name == newMember.name)) {
                try {
                  await FirestoreService.addMemberToGroup(
                    _group.id,
                    newMember.name,
                    newMember.email,
                  );

                  if (!mounted) return;
                  setState(() {
                    _group = _group.copyWith(
                      members: [..._group.members, newMember],
                    );
                  });
                  widget.onGroupUpdated(_group);
                  Navigator.pop(dialogCtx);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString()}')),
                  );
                }
              }
            },
            child: const Text('Add', style: TextStyle(color: kPrimaryColor)),
          ),
        ],
      ),
    );
  }

  void _markPaid(String memberName, String memberEmail) async {
    final isCurrentUser =
        memberEmail == currentUserEmail || memberName == 'You';

    if (!isCurrentUser) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You can only mark your own payment')),
      );
      return;
    }

    final balances = BalanceCalculator.calculateBalances(_group);
    final balance = balances[memberName] ?? 0;

    if (balance >= -0.01) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nothing to pay')));
      return;
    }

    final receiver = _group.members.firstWhere(
      (m) => (balances[m.name] ?? 0) > 0,
      orElse: () => _group.members.first,
    );
    final amountOwed = balance.abs();
    final alreadyPending = _group.settlements.any(
      (s) =>
          s.from == memberName &&
          s.to == receiver.name &&
          (s.status == 'paid_pending_confirmation' ||
              s.status == 'pending_confirmation'),
    );

    if (alreadyPending) return;

    final settlement = Settlement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      from: memberName,
      to: receiver.name,
      payerEmail: currentUserEmail,
      receiverEmail: receiver.email,
      amount: amountOwed,
      status: 'paid_pending_confirmation',
      createdAt: DateTime.now(),
    );

    try {
      final result = await FirestoreService.createSettlement(
        _group.id,
        settlement,
        _group.currency,
      );
      if (!mounted) return;
      if (!result.createdNew) return;

      setState(() {
        _group = _group.copyWith(
          settlements: [..._group.settlements, result.settlement],
        );
      });

      widget.onGroupUpdated(_group);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
      }
    }
  }

  void _confirmSettlement(Settlement settlement) async {
    if (settlement.status != 'paid_pending_confirmation') {
      return;
    }

    // Only the receiver / creditor can confirm receipt.
    if (settlement.receiverEmail != currentUserEmail) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the recipient can confirm payment')),
      );
      return;
    }

    try {
      // Update Firestore
      await FirestoreService.updateSettlementStatus(
        _group.id,
        settlement.id,
        'confirmed',
      );

      // Local state update for immediate UI feedback
      setState(() {
        _group = _group.copyWith(
          settlements: _group.settlements.map((s) {
            if (s.id == settlement.id) {
              return Settlement(
                id: s.id,
                from: s.from,
                to: s.to,
                payerEmail: s.payerEmail,
                receiverEmail: s.receiverEmail,
                amount: s.amount,
                status: 'confirmed',
                createdAt: s.createdAt,
                relatedExpenseId: s.relatedExpenseId,
              );
            }
            return s;
          }).toList(),
        );
      });

      widget.onGroupUpdated(_group);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final balances = BalanceCalculator.calculateBalances(_group);
    final summary = BalanceCalculator.getUserSummary(_group);
    final totalExpenses = BalanceCalculator.getTotalExpenses(_group);
    final scheme = Theme.of(context).colorScheme;
    final surfaceCard = Theme.of(context).cardColor;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _group.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _group.emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => shareGroupInvite(context, _group),
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Invite'),
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Summary
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: surfaceCard,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: kPrimaryColor.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your Balance',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            summary['text'] as String,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Total Expenses',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${totalExpenses.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'Outstanding',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    ' ${BalanceCalculator.getGroupOutstanding(_group).toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: scheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Members
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Members (${_group.members.length})',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.add_circle,
                            color: kPrimaryColor,
                          ),
                          onPressed: _addMember,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ..._group.members.map((member) {
                      final balance = balances[member.name] ?? 0;
                      final receiverForMember = _group.members.firstWhere(
                        (m) => (balances[m.name] ?? 0) > 0,
                        orElse: () => _group.members.first,
                      );
                      final hasPending = _group.settlements.any(
                        (s) =>
                            s.from == member.name &&
                            s.to == receiverForMember.name &&
                            (s.status == 'paid_pending_confirmation' ||
                                s.status == 'pending_confirmation'),
                      );
                      final isCurrentMember =
                          member.email == currentUserEmail ||
                          member.name == 'You';
                      String statusText = 'Settled';
                      Color statusColor = kPrimaryColor;

                      if (hasPending) {
                        statusText = 'Waiting for confirmation';
                        statusColor = scheme.tertiary;
                      } else if (balance > 0) {
                        statusText =
                            'Is owed ${_group.currency} ${balance.toStringAsFixed(2)}';
                        statusColor = kPrimaryColor;
                      } else if (balance < 0) {
                        statusText =
                            'Owes ${_group.currency} ${balance.abs().toStringAsFixed(2)}';
                        statusColor = scheme.error;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: surfaceCard,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  member.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  statusText,
                                  style: TextStyle(
                                    color: statusColor,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            if (isCurrentMember && balance < 0 && !hasPending)
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: kPrimaryColor.withOpacity(
                                    0.2,
                                  ),
                                  foregroundColor: kPrimaryColor,
                                ),
                                onPressed: () =>
                                    _markPaid(member.name, member.email),
                                child: const Text(
                                  'Mark Paid',
                                  style: TextStyle(fontSize: 12),
                                ),
                              )
                            else if (isCurrentMember && balance < 0 && hasPending)
                              Text(
                                'Waiting for confirmation',
                                style: TextStyle(
                                  color: scheme.tertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                    const SizedBox(height: 20),

                    // Expenses
                    const Text(
                      'Expenses',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_group.expenses.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'No expenses yet',
                          style:
                              TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    else
                      ..._group.expenses.map((expense) {
                        return _buildExpenseCard(expense);
                      }),
                    const SizedBox(height: 20),

                    // Settlements
                    if (_group.settlements.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Settlements',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ..._group.settlements.map((settlement) {
                            return _buildSettlementCard(settlement);
                          }),
                          const SizedBox(height: 20),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kPrimaryColor,
        onPressed: _addExpense,
        child: Icon(Icons.add, color: scheme.onPrimary),
      ),
    );
  }

  Widget _buildExpenseCard(Expense expense) {
    final scheme = Theme.of(context).colorScheme;
    final surfaceCard = Theme.of(context).cardColor;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    expense.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Paid by ${expense.paidBy}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Text(
                '${_group.currency} ${expense.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: kPrimaryColor,
                ),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text(
                    'Split Details',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  ...expense.splits.map((split) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            split.memberName,
                            style:
                                TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          Text(
                            '${_group.currency} ${split.amount.toStringAsFixed(2)}',
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettlementCard(Settlement settlement) {
    final scheme = Theme.of(context).colorScheme;
    final surfaceCard = Theme.of(context).cardColor;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: settlement.status == 'confirmed'
              ? kPrimaryColor.withValues(alpha: 0.3)
              : scheme.tertiary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${settlement.from} → ${settlement.to}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    settlement.status == 'confirmed'
                        ? 'Confirmed ✓'
                        : 'Awaiting Confirmation',
                    style: TextStyle(
                      color: settlement.status == 'confirmed'
                          ? kPrimaryColor
                          : scheme.tertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              Text(
                '${_group.currency} ${settlement.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: kPrimaryColor,
                ),
              ),
            ],
          ),
          // Only creditor can confirm payments marked by debtor
          if (settlement.status == 'paid_pending_confirmation' &&
              settlement.receiverEmail == currentUserEmail)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                children: [
                  // 🔹 Confirm button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimaryColor,
                        foregroundColor: scheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: () => _confirmSettlement(settlement),
                      child: const Text(
                        'Confirm Receipt',
                        style: TextStyle(fontSize: 12),
                      ),
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

// ============================================================================
// ADD EXPENSE DIALOG
// ============================================================================

class AddExpenseDialog extends StatefulWidget {
  final Group group;
  final Function(Expense) onExpenseAdded;

  const AddExpenseDialog({
    Key? key,
    required this.group,
    required this.onExpenseAdded,
  }) : super(key: key);

  @override
  State<AddExpenseDialog> createState() => _AddExpenseDialogState();
}

class _AddExpenseDialogState extends State<AddExpenseDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  late String _paidBy;
  late List<String> _selectedMembers;
  bool _useCustomSplit = false;
  late Map<String, TextEditingController> _customSplitControllers;

  @override
  void initState() {
    super.initState();
    _paidBy = widget.group.members.isNotEmpty
        ? widget.group.members[0].name
        : 'You';
    _selectedMembers = widget.group.members.map((m) => m.name).toList();
    _customSplitControllers = {};
    for (var member in widget.group.members) {
      _customSplitControllers[member.name] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    for (var controller in _customSplitControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _saveExpense() async {
    if (_titleController.text.isEmpty || _amountController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
      return;
    }

    final amount = double.parse(_amountController.text);
    List<Split> splits = [];

    if (_useCustomSplit) {
      double total = 0;
      final tempSplits = <Split>[];

      for (var member in _selectedMembers) {
        final customAmount =
            double.tryParse(_customSplitControllers[member]?.text ?? '') ?? 0;
        if (customAmount > 0) {
          tempSplits.add(Split(memberName: member, amount: customAmount));
          total += customAmount;
        }
      }

      // Auto-balance: distribute rounding difference to last member
      if (tempSplits.isNotEmpty && (total - amount).abs() > 0.01) {
        // Adjust the last person's split to match the total
        final lastSplit = tempSplits.last;
        final adjustment = amount - (total - lastSplit.amount);
        tempSplits[tempSplits.length - 1] = Split(
          memberName: lastSplit.memberName,
          amount: adjustment,
        );
        splits = tempSplits;
      } else if (tempSplits.isNotEmpty && (total - amount).abs() <= 0.01) {
        // Close enough with rounding - auto adjust last member
        final lastSplit = tempSplits.last;
        final newAmount = amount - (total - lastSplit.amount);
        tempSplits[tempSplits.length - 1] = Split(
          memberName: lastSplit.memberName,
          amount: newAmount,
        );
        splits = tempSplits;
      } else if (tempSplits.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter amounts for at least one person'),
          ),
        );
        return;
      }
    } else {
      // Equal split
      final amountPerPerson = amount / _selectedMembers.length;
      for (var i = 0; i < _selectedMembers.length; i++) {
        // Auto-balance: give any rounding to the last person
        final adjustedAmount = i == _selectedMembers.length - 1
            ? amount - (amountPerPerson * (_selectedMembers.length - 1))
            : amountPerPerson;
        splits.add(
          Split(memberName: _selectedMembers[i], amount: adjustedAmount),
        );
      }
    }

    final expense = Expense(
      id: DateTime.now().toString(),
      title: _titleController.text,
      amount: amount,
      paidBy: _paidBy,
      splits: splits,
      createdAt: DateTime.now(),
      groupId: widget.group.id,
    );

    try {
      await FirestoreService.createExpense(
        widget.group.id,
        expense,
        currency: widget.group.currency,
      );
      if (!mounted) return;
      widget.onExpenseAdded(expense);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final cardCol = Theme.of(context).cardColor;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Add Expense',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),

              // Title
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  hintText: 'Expense title',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: scaffoldBg,
                ),
              ),
              const SizedBox(height: 12),

              // Amount
              TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Amount',
                  prefixText: '${widget.group.currency} ',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: scaffoldBg,
                ),
              ),
              const SizedBox(height: 12),

              // Paid by
              const Text(
                'Paid by',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _paidBy,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: scaffoldBg,
                ),
                dropdownColor: cardCol,
                onChanged: (value) {
                  if (value != null) setState(() => _paidBy = value);
                },
                items: widget.group.members
                    .map(
                      (m) =>
                          DropdownMenuItem(value: m.name, child: Text(m.name)),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),

              // Split type toggle
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Split Type',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Switch(
                    value: _useCustomSplit,
                    onChanged: (value) =>
                        setState(() => _useCustomSplit = value),
                    activeColor: kPrimaryColor,
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Participants / Custom splits
              const Text(
                'Participants',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              ...widget.group.members.map((member) {
                final isSelected = _selectedMembers.contains(member.name);
                return _useCustomSplit
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(child: Text(member.name)),
                            SizedBox(
                              width: 100,
                              child: TextField(
                                controller:
                                    _customSplitControllers[member.name],
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  hintText: '0',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  filled: true,
                                  fillColor: scaffoldBg,
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : CheckboxListTile(
                        title: Text(member.name),
                        value: isSelected,
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              _selectedMembers.add(member.name);
                            } else {
                              _selectedMembers.remove(member.name);
                            }
                          });
                        },
                        activeColor: kPrimaryColor,
                      );
              }).toList(),
              const SizedBox(height: 20),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryColor,
                      foregroundColor: scheme.onPrimary,
                    ),
                    onPressed: _saveExpense,
                    child: const Text(
                      'Save Expense',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void showComingSoonModal(BuildContext context, String title, IconData icon) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: kPrimaryColor.withValues(alpha: 0.18),
              child: Icon(icon, color: scheme.primary, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "This feature is ready as UI placeholder. Logic/API can be connected next.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
}

void showSettleUpModal(BuildContext context, List<Group> groups) {
  if (groups.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('No groups available')));
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      return Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Settle Up",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              ...groups.expand((group) {
                final balances = BalanceCalculator.calculateBalances(group);
                final debtors = <String, double>{};

                balances.forEach((name, balance) {
                  if (balance < 0) {
                    debtors[name] = balance.abs();
                  }
                });

                return debtors.entries.map((entry) {
                  return settlementRow(
                    sheetCtx,
                    entry.key,
                    '${group.currency} ${entry.value.toStringAsFixed(2)}',
                    group.name,
                  );
                }).toList();
              }).toList(),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryColor,
                    foregroundColor: scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: const Text(
                    "Close",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget settlementRow(
  BuildContext context,
  String name,
  String amount, [
  String? groupName,
]) {
  final scheme = Theme.of(context).colorScheme;
  final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: scaffoldBg,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
            Text(
              amount,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        if (groupName != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Group: $groupName',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
      ],
    ),
  );
}

void showRemindModal(
  BuildContext context,
  List<Group> groups, {
  required bool isPremium,
  required bool premiumFeatureAllowed,
  required VoidCallback onShowPremium,
}) {
  final reminders = <Map<String, dynamic>>[];

  for (final group in groups) {
    final groupReminders = ReminderGenerator.getPendingReminders(group);
    for (final reminder in groupReminders) {
      reminders.add({...reminder, 'groupName': group.name});
    }
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      final scaffoldBg = Theme.of(sheetCtx).scaffoldBackgroundColor;
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.78,
          child: Column(
            children: [
              const SizedBox(height: 14),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 18),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Pending Reminders',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              Expanded(
                child: reminders.isEmpty
                    ? Center(
                        child: Text(
                          'No pending reminders',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        itemCount: reminders.length,
                        itemBuilder: (listCtx, index) {
                          final item = reminders[index];
                          final isPending =
                              item['type'] == 'paid_pending_confirmation';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: scaffoldBg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isPending
                                    ? scheme.tertiary.withValues(alpha: 0.65)
                                    : scheme.error.withValues(alpha: 0.65),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  isPending
                                      ? Icons.pending_actions
                                      : Icons.payment,
                                  color: isPending
                                      ? scheme.tertiary
                                      : scheme.error,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['message'] ?? '',
                                        style: TextStyle(
                                          color: scheme.onSurface,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          height: 1.3,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Group: ${item['groupName']}',
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        height: 32,
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: kPrimaryColor,
                                            foregroundColor: scheme.onPrimary,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                          ),
                                          onPressed: () async {
                                            if (!premiumFeatureAllowed) {
                                              Navigator.pop(sheetCtx);
                                              onShowPremium();
                                              return;
                                            }
                                            try {
                                              await sendWhatsAppReminder(
                                                memberName:
                                                    item['member'] ?? '',
                                                currency:
                                                    item['currency']?.toString() ??
                                                    currentCurrency,
                                                amount: (item['amount']
                                                        as double)
                                                    .toStringAsFixed(2),
                                                groupName:
                                                    item['groupName'] ?? '',
                                                type: item['type'] ?? 'unpaid',
                                              );
                                            } catch (_) {
                                              if (listCtx.mounted) {
                                                ScaffoldMessenger.of(listCtx)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'Could not open WhatsApp',
                                                    ),
                                                  ),
                                                );
                                              }
                                            }
                                          },
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (!isPremium) ...[
                                                const Text(
                                                  '👑 ',
                                                  style: TextStyle(fontSize: 11),
                                                ),
                                              ],
                                              const Text(
                                                'Send WhatsApp',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryColor,
                      foregroundColor: scheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text(
                      'Close',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void showExportPdfModal(
  BuildContext context,
  Group group, {
  required bool isPremium,
  required bool premiumFeatureAllowed,
  required VoidCallback onShowPremium,
}) {
  if (!premiumFeatureAllowed) {
    onShowPremium();
    return;
  }
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.picture_as_pdf_outlined,
                color: kPrimaryColor,
                size: 46,
              ),
              const SizedBox(height: 16),
              Text(
                'Export PDF',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Export ${group.name} report with expenses and balances.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryColor,
                    foregroundColor: scheme.onPrimary,
                  ),
                  onPressed: () async {
                    Navigator.pop(sheetCtx);
                    await PdfGenerator.generateAndPrintExpenseReport(group);
                  },
                  child: const Text(
                    'Generate PDF',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void showAutoBalanceModal(
  BuildContext context,
  List<Group> groups,
  void Function(Group updatedGroup) onGroupUpdated, {
  required bool isPremium,
  required bool premiumFeatureAllowed,
  required VoidCallback onShowPremium,
}) {
  final smartItems = <Map<String, dynamic>>[];
  for (final group in groups) {
    final suggestions = BalanceCalculator.generateSmartSettlements(group);
    for (final suggestion in suggestions) {
      smartItems.add({'group': group, 'settlement': suggestion});
    }
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      final scaffoldBg = Theme.of(sheetCtx).scaffoldBackgroundColor;
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.70,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
            child: Column(
              children: [
                const Icon(
                  Icons.balance_outlined,
                  color: kPrimaryColor,
                  size: 46,
                ),
                const SizedBox(height: 16),
                Text(
                  'Auto Balance',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Smart settle suggests the minimum transactions to clear group balances.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 22),
                if (smartItems.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scaffoldBg,
                      borderRadius: BorderRadius.circular(16),
                      border:
                          Border.all(color: kPrimaryColor.withOpacity(0.3)),
                    ),
                    child: Text(
                      'No smart settlements needed right now.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  )
                else
                  ...smartItems.map((item) {
                    final group = item['group'] as Group;
                    final suggestion = item['settlement'] as Settlement;
                    final debtorMember = group.members.firstWhere(
                      (m) => m.name == suggestion.from,
                      orElse: () => Member(name: suggestion.from, email: ''),
                    );
                    final receiverMember = group.members.firstWhere(
                      (m) => m.name == suggestion.to,
                      orElse: () => Member(name: suggestion.to, email: ''),
                    );
                    final debtorIsCurrentUser =
                        suggestion.from == 'You' ||
                        debtorMember.email == currentUserEmail;

                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scaffoldBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: kPrimaryColor.withOpacity(0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${suggestion.from} pays ${suggestion.to} ${group.currency} ${suggestion.amount.toStringAsFixed(2)}',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Group: ${group.name}',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              height: 34,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: debtorIsCurrentUser
                                      ? kPrimaryColor
                                      : scheme.tertiary,
                                  foregroundColor: debtorIsCurrentUser
                                      ? scheme.onPrimary
                                      : scheme.onTertiary,
                                ),
                                onPressed: () async {
                                  if (!debtorIsCurrentUser) {
                                    if (!premiumFeatureAllowed) {
                                      Navigator.pop(sheetCtx);
                                      onShowPremium();
                                      return;
                                    }
                                    try {
                                      await sendWhatsAppReminder(
                                        memberName: suggestion.from,
                                        currency: group.currency,
                                        amount: suggestion.amount.toStringAsFixed(2),
                                        groupName: group.name,
                                        type: 'unpaid',
                                      );
                                    } catch (_) {
                                      if (sheetCtx.mounted) {
                                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                                          const SnackBar(
                                            content: Text('Could not open WhatsApp'),
                                          ),
                                        );
                                      }
                                    }
                                    return;
                                  }

                                  final settlementToCreate = Settlement(
                                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                                    from: suggestion.from,
                                    to: suggestion.to,
                                    payerEmail: debtorMember.email.isNotEmpty
                                        ? debtorMember.email
                                        : currentUserEmail,
                                    receiverEmail: receiverMember.email,
                                    amount: suggestion.amount,
                                    status: 'paid_pending_confirmation',
                                    createdAt: DateTime.now(),
                                  );

                                  try {
                                    final result =
                                        await FirestoreService.createSettlement(
                                      group.id,
                                      settlementToCreate,
                                      group.currency,
                                    );
                                    if (!sheetCtx.mounted) return;
                                    if (!result.createdNew) return;

                                    onGroupUpdated(
                                      group.copyWith(
                                        settlements: [
                                          ...group.settlements,
                                          result.settlement,
                                        ],
                                      ),
                                    );
                                  } catch (e) {
                                    if (sheetCtx.mounted) {
                                      ScaffoldMessenger.of(sheetCtx).showSnackBar(
                                        SnackBar(content: Text(e.toString())),
                                      );
                                    }
                                  }
                                },
                                child: Text(
                                  debtorIsCurrentUser
                                      ? 'Create Settlement'
                                      : 'Send WhatsApp',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimaryColor,
                      foregroundColor: scheme.onPrimary,
                    ),
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text(
                      'Got it',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> sendWhatsAppReminder({
  required String memberName,
  required String currency,
  required String amount,
  required String groupName,
  required String type,
}) async {
  String message;
  if (type == 'paid_pending_confirmation') {
    message =
        'Hi $memberName, SettleBro reminder: payment of $currency $amount in $groupName is waiting for confirmation.';
  } else {
    message =
        'Hi $memberName, reminder from SettleBro: you owe $currency $amount in $groupName. Please settle when convenient.';
  }

  final encodedMessage = Uri.encodeComponent(message);
  final uri = Uri.parse('https://wa.me/?text=$encodedMessage');
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened) {
    throw Exception('Could not open WhatsApp');
  }
}

void showInsightsModal(
  BuildContext context,
  List<Group> groups, {
  required bool isPremium,
  required bool premiumFeatureAllowed,
  required VoidCallback onShowPremium,
}) {
  if (!premiumFeatureAllowed) {
    onShowPremium();
    return;
  }
  showModalBottomSheet(
    context: context,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) {
      final scheme = Theme.of(sheetCtx).colorScheme;
      final scaffoldBg = Theme.of(sheetCtx).scaffoldBackgroundColor;
      return Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Insights",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 20),
              ...groups.map((group) {
                final insights = InsightsCalculator.getGroupInsights(group);

                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scaffoldBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kPrimaryColor.withOpacity(0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            group.emoji,
                            style: const TextStyle(fontSize: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              group.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: scheme.outline),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Total Spent',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${group.currency} ${(insights['totalExpenses'] as double).toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: kPrimaryColor,
                                ),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Expenses',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${insights['expenseCount']} transactions',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: scheme.outline),
                      const SizedBox(height: 12),
                      if ((insights['topSpender'] as String).isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Top Spender',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${insights['topSpender']} paid ${group.currency} ${(insights['topSpenderAmount'] as double).toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      if ((insights['mostOwedUser'] as String).isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Most Owed',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${insights['mostOwedUser']} is owed ${group.currency} ${(insights['mostOwedAmount'] as double).toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: kPrimaryColor,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                );
              }).toList(),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryColor,
                    foregroundColor: scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: const Text(
                    'Close',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
