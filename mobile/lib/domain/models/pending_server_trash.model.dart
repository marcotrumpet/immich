class PendingServerTrash {
  final String localId;
  final String remoteId;
  final String checksum;
  final DateTime deletedAt;

  const PendingServerTrash({
    required this.localId,
    required this.remoteId,
    required this.checksum,
    required this.deletedAt,
  });

  bool isDue(DateTime now, Duration quarantine) => !now.isBefore(deletedAt.add(quarantine));

  Map<String, Object> toJson() => {
    'localId': localId,
    'remoteId': remoteId,
    'checksum': checksum,
    'deletedAt': deletedAt.toUtc().millisecondsSinceEpoch,
  };

  factory PendingServerTrash.fromJson(Map<String, dynamic> json) => PendingServerTrash(
    localId: json['localId'] as String,
    remoteId: json['remoteId'] as String,
    checksum: json['checksum'] as String,
    deletedAt: DateTime.fromMillisecondsSinceEpoch(json['deletedAt'] as int, isUtc: true),
  );
}
