import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/pending_server_trash.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:logging/logging.dart';

class LocalDeletionSyncService {
  final LocalAssetRepository _localAssetRepository;
  final AssetService _assetService;
  final DateTime Function() _clock;
  final Logger _log = Logger("LocalDeletionSyncService");

  LocalDeletionSyncService({
    required LocalAssetRepository localAssetRepository,
    required AssetService assetService,
    DateTime Function()? clock,
  }) : _localAssetRepository = localAssetRepository,
       _assetService = assetService,
       _clock = clock ?? DateTime.now;

  bool get isEnabled => CurrentPlatform.isIOS && Store.get(StoreKey.syncLocalDeletionsToServer, false);

  Duration get quarantine => Duration(days: Store.get(StoreKey.localDeletionQuarantineDays, 7));

  List<PendingServerTrash> getPending() {
    final raw = Store.tryGet(StoreKey.pendingServerTrash);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(PendingServerTrash.fromJson)
          .toList(growable: false);
    } catch (error, stack) {
      _log.severe("Discarding unreadable pending server trash queue", error, stack);
      return const [];
    }
  }

  Future<void> _savePending(Iterable<PendingServerTrash> pending) {
    if (pending.isEmpty) {
      return Store.delete(StoreKey.pendingServerTrash);
    }
    return Store.put(StoreKey.pendingServerTrash, jsonEncode(pending.map((entry) => entry.toJson()).toList()));
  }

  Future<void> clearPending() => Store.delete(StoreKey.pendingServerTrash);

  Future<int> enqueue(Iterable<String> deletedLocalIds) async {
    if (!isEnabled || deletedLocalIds.isEmpty) {
      return 0;
    }

    final matches = await _localAssetRepository.getBackedUpRemoteMatches(deletedLocalIds);
    if (matches.isEmpty) {
      return 0;
    }

    final pending = {for (final entry in getPending()) entry.remoteId: entry};
    final now = _clock().toUtc();
    var added = 0;
    for (final match in matches) {
      if (pending.containsKey(match.remoteId)) {
        continue;
      }
      pending[match.remoteId] = PendingServerTrash(
        localId: match.localId,
        remoteId: match.remoteId,
        checksum: match.checksum,
        deletedAt: now,
      );
      added++;
    }

    await _savePending(pending.values);
    _log.info("Queued $added remote assets for server trash after local deletion");
    return added;
  }

  Future<int> processDue() async {
    if (!isEnabled) {
      return 0;
    }

    final pending = getPending();
    final now = _clock().toUtc();
    final due = pending.where((entry) => entry.isDue(now, quarantine)).toList(growable: false);
    if (due.isEmpty) {
      return 0;
    }

    final present = await _localAssetRepository.getStillPresent(
      ids: due.map((entry) => entry.localId),
      checksums: due.map((entry) => entry.checksum),
    );
    final toTrash = due
        .where((entry) => !present.contains(entry.localId) && !present.contains(entry.checksum))
        .map((entry) => entry.remoteId)
        .toList(growable: false);

    try {
      for (final slice in toTrash.slices(kDriftMaxChunk)) {
        await _assetService.trash(slice);
      }
    } catch (error, stack) {
      _log.warning("Moving locally deleted assets to the server trash failed, will retry", error, stack);
      return 0;
    }

    final dueIds = due.map((entry) => entry.remoteId).toSet();
    await _savePending(pending.where((entry) => !dueIds.contains(entry.remoteId)));
    _log.info("Moved ${toTrash.length} locally deleted assets to the server trash");
    return toTrash.length;
  }
}
