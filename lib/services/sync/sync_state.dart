import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncSummary {
  final int nodeCount;
  final DateTime? lastSuccessAt;
  final String? lastError;
  final String? nodeIds;

  const SyncSummary({
    required this.nodeCount,
    required this.lastSuccessAt,
    required this.lastError,
    required this.nodeIds,
  });

  SyncSummary copyWith({
    int? nodeCount,
    DateTime? lastSuccessAt,
    String? lastError,
    String? nodeIds,
  }) {
    return SyncSummary(
      nodeCount: nodeCount ?? this.nodeCount,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      lastError: lastError,
      nodeIds: nodeIds ?? this.nodeIds,
    );
  }
}

class SyncStateStore {
  SyncStateStore._();

  static final SyncStateStore instance = SyncStateStore._();

  static const _nodeCountKey = 'sync.nodeCount';
  static const _lastSuccessKey = 'sync.lastSuccessAt';
  static const _lastErrorKey = 'sync.lastError';
  static const _nodeIdsKey = 'sync.nodeIds';

  final ValueNotifier<SyncSummary> summary = ValueNotifier<SyncSummary>(
    const SyncSummary(
      nodeCount: 0,
      lastSuccessAt: null,
      lastError: null,
      nodeIds: null,
    ),
  );

  int get lastNodeCount => summary.value.nodeCount;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final nodeCount = prefs.getInt(_nodeCountKey) ?? 0;
    final lastSuccessMillis = prefs.getInt(_lastSuccessKey);
    final lastError = prefs.getString(_lastErrorKey);
    final nodeIds = prefs.getString(_nodeIdsKey);

    summary.value = SyncSummary(
      nodeCount: nodeCount,
      lastSuccessAt: lastSuccessMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(lastSuccessMillis)
          : null,
      lastError: lastError,
      nodeIds: nodeIds,
    );
  }

  Future<void> recordSuccess({required int nodeCount, String? nodeIds}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setInt(_nodeCountKey, nodeCount);
    await prefs.setInt(_lastSuccessKey, now.millisecondsSinceEpoch);
    if (nodeIds != null) {
      await prefs.setString(_nodeIdsKey, nodeIds);
    }
    await prefs.remove(_lastErrorKey);

    summary.value = SyncSummary(
      nodeCount: nodeCount,
      lastSuccessAt: now,
      lastError: null,
      nodeIds: nodeIds ?? summary.value.nodeIds,
    );
  }

  Future<void> clearNodes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_nodeCountKey, 0);
    await prefs.remove(_nodeIdsKey);
    summary.value = summary.value.copyWith(nodeCount: 0, nodeIds: "");
  }

  void recordTransientError(String message) {
    summary.value = summary.value.copyWith(lastError: message);
  }

  void clearTransientError(String message) {
    if (summary.value.lastError == message) {
      summary.value = summary.value.copyWith();
    }
  }

  Future<void> recordError(String message) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastErrorKey, message);
    summary.value = summary.value.copyWith(lastError: message);
  }
}
