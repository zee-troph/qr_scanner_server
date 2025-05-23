import 'dart:io';
import 'package:postgres/postgres.dart';
import '../lib/utils/database_actions.dart';

/// Attendance server that manages users (with passwords), admins,
/// QR sessions, and attendance records over WebSocket. {$ECUR3_PA55W0RD}
void main(List<String> args) async {
  final dbUrl = Platform.environment['DATABASE_URL'];
  final port = int.parse(Platform.environment['PORT'] ?? '8080');

  if (dbUrl == null) {
    print('DATABASE_URL is not set.');
    return;
  } else {
    print('Database URL: $dbUrl');
  }
  final uri = Uri.parse(dbUrl);

  final db = PostgreSQLConnection(
    uri.host,
    uri.port,
    uri.pathSegments.first,
    username: uri.userInfo.split(':')[0],
    password: uri.userInfo.split(':')[1],
    useSSL: true,
  );

  await db.open();

  print('[DB] Database opened.');
  createSchema(db);
  prepareServer(db, port);
}
