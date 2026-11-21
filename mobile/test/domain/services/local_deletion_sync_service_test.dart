import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_deletion_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../service.mocks.dart';

void main() {
  late LocalDeletionSyncService sut;
  late MockLocalAssetRepository mockLocalAssetRepository;
  late MockAssetService mockAssetService;
  late Drift db;
  late DateTime now;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    mockLocalAssetRepository = MockLocalAssetRepository();
    mockAssetService = MockAssetService();
    now = DateTime.utc(2026, 11, 1);
    sut = LocalDeletionSyncService(
      localAssetRepository: mockLocalAssetRepository,
      assetService: mockAssetService,
      clock: () => now,
    );

    await Store.put(StoreKey.syncLocalDeletionsToServer, true);
    await Store.put(StoreKey.localDeletionQuarantineDays, 7);
    await Store.delete(StoreKey.pendingServerTrash);

    when(() => mockAssetService.trash(any())).thenAnswer((_) async {});
    when(
      () => mockLocalAssetRepository.getBackedUpRemoteMatches(any()),
    ).thenAnswer((_) async => [(localId: 'local-1', remoteId: 'remote-1', checksum: 'sum-1')]);
    when(
      () => mockLocalAssetRepository.getStillPresent(
        ids: any(named: 'ids'),
        checksums: any(named: 'checksums'),
      ),
    ).thenAnswer((_) async => <String>{});
  });

  test('does nothing when the setting is off', () async {
    await Store.put(StoreKey.syncLocalDeletionsToServer, false);

    expect(await sut.enqueue(['local-1']), 0);
    verifyNever(() => mockLocalAssetRepository.getBackedUpRemoteMatches(any()));
  });

  test('queues backed up assets without trashing them immediately', () async {
    expect(await sut.enqueue(['local-1']), 1);

    expect(await sut.processDue(), 0);
    expect(sut.getPending().single.remoteId, 'remote-1');
    verifyNever(() => mockAssetService.trash(any()));
  });

  test('keeps the original deletion time when the same asset is reported again', () async {
    await sut.enqueue(['local-1']);
    now = now.add(const Duration(days: 3));
    expect(await sut.enqueue(['local-1']), 0);

    expect(sut.getPending().single.deletedAt, DateTime.utc(2026, 11, 1));
  });

  test('trashes on the server once the quarantine is over', () async {
    await sut.enqueue(['local-1']);
    now = now.add(const Duration(days: 7));

    expect(await sut.processDue(), 1);
    verify(() => mockAssetService.trash(['remote-1'])).called(1);
    expect(sut.getPending(), isEmpty);
  });

  test('skips assets restored on the device during the quarantine', () async {
    await sut.enqueue(['local-1']);
    now = now.add(const Duration(days: 8));
    when(
      () => mockLocalAssetRepository.getStillPresent(
        ids: any(named: 'ids'),
        checksums: any(named: 'checksums'),
      ),
    ).thenAnswer((_) async => {'sum-1'});

    expect(await sut.processDue(), 0);
    verifyNever(() => mockAssetService.trash(any()));
    expect(sut.getPending(), isEmpty);
  });

  test('keeps the queue when the server call fails', () async {
    await sut.enqueue(['local-1']);
    now = now.add(const Duration(days: 8));
    when(() => mockAssetService.trash(any())).thenThrow(Exception('offline'));

    expect(await sut.processDue(), 0);
    expect(sut.getPending().single.remoteId, 'remote-1');
  });

  test('clearPending drops every queued deletion', () async {
    await sut.enqueue(['local-1']);
    await sut.clearPending();

    expect(sut.getPending(), isEmpty);
  });
}
