import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import '../lib/utils/socket_listener.dart';

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
  _createSchema(db);

  final manager = SocketManager();
  await manager.startServer(
    address: InternetAddress.anyIPv4,
    port: port,
  );
  print('[Socket] Server started on 0.0.0.0:8080');

  manager.processPayload = (payload, socket) {
    print('[Payload] Received: $payload');
    if (payload is! Map<String, dynamic> || !payload.containsKey('command'))
      return;
    switch (payload['command'] as String) {
      case 'create_user':
        _handleCreateUser(db, payload, socket, manager);
        break;
      case 'get_attendances':
        _handleRequestAttendances(db, payload, socket, manager);
        break;
      case 'get_sessions':
        _handleRequestSessions(db, payload, socket, manager);
        break;
      case 'create_admin':
        _handleCreateAdmin(db, payload, socket, manager);
        break;
      case 'login':
        _handleLogin(db, payload, socket, manager);
        break;
      case 'create_session':
        _handleCreateSession(db, payload, socket, manager);
        break;
      case 'attendance':
        _handleAttendance(db, payload, socket, manager);
        break;
      default:
        print('[Error] Unknown command:  ${payload['command']}');
    }
  };

  print('[Server] Server running on port 8080');
}

/// --- UTILITY FUNCTIONS ---

String _hashPassword(String password) {
  final hash = sha256.convert(utf8.encode(password)).toString();
  print('[Auth] Hashed password: $hash');
  return hash;
}

/// --- DB SCHEMA CREATION ---

Future<void> _createSchema(PostgreSQLConnection db) async {
  print('[DB] Creating schema if not exists...');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      password TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS admins (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      password TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      admin_id TEXT NOT NULL,
      code TEXT NOT NULL,
      expires TEXT NOT NULL,
      FOREIGN KEY(admin_id) REFERENCES users(id)
    );
    CREATE TABLE IF NOT EXISTS attendances (
      id SERIAL PRIMARY KEY,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      qr_primary_key TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      FOREIGN KEY(session_id) REFERENCES sessions(id),
      FOREIGN KEY(user_id) REFERENCES users(id)
    );
  ''');
  print('[DB] Schema created.');
}

/// --- HANDLERS ---

Future<void> _handleRequestSessions(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final adminId = p['admin_id'] as String;

  final result = await db.mappedResultsQuery(
    '''
    SELECT id, code, expires FROM sessions WHERE admin_id = @adminId
    ''',
    substitutionValues: {'adminId': adminId},
  );

  final sessionList = result
      .map((row) => {
            'session_id': row['sessions']!['id'],
            'code': row['sessions']!['code'],
            'expires': row['sessions']!['expires'],
          })
      .toList();

  m.replyTo(p, {'command': 'session_list', 'sessions': sessionList}, socket);
}

Future<void> _handleRequestAttendances(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final sessionId = p['session_id'] as String;

  final result = await db.mappedResultsQuery(
    '''
    SELECT user_id, timestamp FROM attendances WHERE session_id = @sessionId
    ''',
    substitutionValues: {'sessionId': sessionId},
  );

  final attendList = result
      .map((row) => {
            'user_id': row['attendances']!['user_id'],
            'timestamp': row['attendances']!['timestamp'],
          })
      .toList();

  m.replyTo(
      p,
      {
        'command': 'attendance_list',
        'attendances': attendList,
      },
      socket);
}

Future<void> _handleCreateUser(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final id = p['id'] as String;
  final name = p['name'] as String;
  final password = p['password'] as String;
  final hashed = _hashPassword(password);

  await db.execute(
    '''
    INSERT INTO users (id, name, password)
    VALUES (@id, @name, @password)
    ON CONFLICT (id) DO NOTHING
    ''',
    substitutionValues: {'id': id, 'name': name, 'password': hashed},
  );

  m.replyTo(p, {'command': 'create_user_ack', 'id': id}, socket);
}

Future<void> _handleCreateAdmin(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final id = p['id'] as String;
  final name = p['name'] as String;
  final password = p['password'] as String;
  final hashed = _hashPassword(password);

  await db.execute(
    '''
    INSERT INTO admins (id, name, password)
    VALUES (@id, @name, @password)
    ON CONFLICT (id) DO NOTHING
    ''',
    substitutionValues: {'id': id, 'name': name, 'password': hashed},
  );

  m.replyTo(p, {'command': 'create_admin_ack', 'id': id}, socket);
}

Future<void> _handleLogin(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final id = p['id'] as String;
  final password = p['password'] as String;
  final role = p['role'] as String;
  final hashed = _hashPassword(password);

  final result = await db.mappedResultsQuery(
    '''
    SELECT id, name FROM ${role}s
    WHERE id = @id AND password = @password
    ''',
    substitutionValues: {'id': id, 'password': hashed},
  );

  if (result.isNotEmpty) {
    final row = result.first['${role}s']!;
    m.replyTo(
        p,
        {
          'command': 'login_ack',
          'status': 'success',
          'id': row['id'],
          'name': row['name'],
          'role': role,
        },
        socket);
  } else {
    m.replyTo(
        p,
        {
          'command': 'login_ack',
          'status': 'failed',
          'reason': 'invalid_credentials',
        },
        socket);
  }
}

Future<void> _handleCreateSession(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final sessionId = p['session_id'] as String;
  final adminId = p['admin_id'] as String;
  final code = p['code'] as String;
  final expires = p['expires'] as String;

  await db.execute(
    '''
    INSERT INTO sessions (id, admin_id, code, expires)
    VALUES (@id, @adminId, @code, @expires)
    ''',
    substitutionValues: {
      'id': sessionId,
      'adminId': adminId,
      'code': code,
      'expires': expires,
    },
  );

  m.replyTo(
      p,
      {
        'command': 'create_session_ack',
        'session_id': sessionId,
        'code': code,
        'expires': expires,
      },
      socket);
}

Future<void> _handleAttendance(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) async {
  final userId = p['user_id'] as String;
  final sessionId = p['session_id'] as String;
  final now = DateTime.now().toIso8601String();

  final sel = await db.mappedResultsQuery(
    'SELECT code, expires FROM sessions WHERE id = @sessionId',
    substitutionValues: {'sessionId': sessionId},
  );

  if (sel.isEmpty) {
    m.replyTo(
        p,
        {
          'command': 'attendance_nok',
          'reason': 'invalid_session',
        },
        socket);
    return;
  }

  final expiresTs = DateTime.parse(sel.first['sessions']!['expires']);
  if (DateTime.now().isAfter(expiresTs)) {
    m.replyTo(p, {'command': 'attendance_nok', 'reason': 'expired'}, socket);
    return;
  }

  final result = await db.query(
    '''
    SELECT 1 FROM attendances
    WHERE session_id = @sessionId AND user_id = @userId
    ''',
    substitutionValues: {'sessionId': sessionId, 'userId': userId},
  );

  if (result.isNotEmpty) {
    m.replyTo(
        p,
        {
          'command': 'attendance_nok',
          'reason': 'You have already signed the attendance previously',
        },
        socket);
    return;
  }

  final attendanceKey = '$sessionId-$userId';

  await db.execute(
    '''
    INSERT INTO attendances (qr_primary_key, session_id, user_id, timestamp)
    VALUES (@key, @sessionId, @userId, @timestamp)
    ''',
    substitutionValues: {
      'key': attendanceKey,
      'sessionId': sessionId,
      'userId': userId,
      'timestamp': now,
    },
  );

  m.replyTo(
      p,
      {
        'command': 'new_attendance',
        'session_id': sessionId,
        'user_id': userId,
        'timestamp': now,
      },
      socket);
}
