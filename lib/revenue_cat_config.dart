import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

// =============================================================================
// TODO: RevenueCat — replace with your iOS *public* SDK key from the dashboard
// (Project settings → API keys → Apple App Store).
// =============================================================================
const String kRevenueCatIosPublicSdkKey = 'appl_REPLACE_WITH_REVENUECAT_IOS_PUBLIC_KEY';

// =============================================================================
// TODO: App Store Connect — create auto-renewable subscriptions with these IDs,
// add them to a subscription group, then mirror them in RevenueCat products and
// attach to entitlement [kPremiumEntitlementId].
// =============================================================================
const String kPremiumMonthlyProductId = 'settlebro_premium_monthly';
const String kPremiumYearlyProductId = 'settlebro_premium_yearly';

/// RevenueCat entitlement identifier granting premium access.
const String kPremiumEntitlementId = 'premium';

bool get revenueCatPlatformSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<void> configureRevenueCatForIos({String? appUserId}) async {
  if (!revenueCatPlatformSupported) return;
  await Purchases.setLogLevel(kDebugMode ? LogLevel.debug : LogLevel.info);
  await Purchases.configure(PurchasesConfiguration(kRevenueCatIosPublicSdkKey));
  if (appUserId != null && appUserId.isNotEmpty) {
    try {
      await Purchases.logIn(appUserId);
    } catch (_) {}
  }
}

Future<void> revenueCatLogInIfNeeded(String uid) async {
  if (!revenueCatPlatformSupported || uid.isEmpty) return;
  try {
    await Purchases.logIn(uid);
  } catch (_) {}
}

bool customerInfoHasPremium(CustomerInfo info) {
  final ent = info.entitlements.all[kPremiumEntitlementId];
  return ent?.isActive == true;
}

/// Resolves a package from the current offering using App Store product IDs,
/// then falls back to RevenueCat [PackageType.monthly] / [PackageType.annual].
Package? packageForPlan(List<Package> packages, {required bool yearly}) {
  final targetId =
      yearly ? kPremiumYearlyProductId : kPremiumMonthlyProductId;
  for (final p in packages) {
    if (p.storeProduct.identifier == targetId) return p;
  }
  final fallbackType = yearly ? PackageType.annual : PackageType.monthly;
  for (final p in packages) {
    if (p.packageType == fallbackType) return p;
  }
  return null;
}
