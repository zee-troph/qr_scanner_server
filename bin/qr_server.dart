import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../lib/utils/socket_listener.dart';

/// Attendance server that manages users (with passwords), admins,
/// QR sessions, and attendance records over WebSocket. {$ECUR3_PA55W0RD}
void main(List<String> args) async {
  final db = sqlite3.open('attendance.db');
  print('[DB] Database opened.');
  _createSchema(db);

  final manager = SocketManager();
  await manager.startServer(
    address: InternetAddress.anyIPv4,
    port: 8080,
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

/// Handles request to retrieve all sessions for a given admin
void _handleRequestSessions(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  final adminId = p['admin_id'] as String;

  final result = db.select(
    '''
    SELECT id, code, expires
      FROM sessions
     WHERE admin_id = ?
  ''',
    [adminId],
  );

  final sessionList = result
      .map(
        (row) => {
          'session_id': row['id'],
          'code': row['code'],
          'expires': row['expires'],
        },
      )
      .toList();

  m.replyTo(p, {'command': 'session_list', 'sessions': sessionList}, socket);
}

/// Handles request to retrieve all attendances for a given session by session ID
void _handleRequestAttendances(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  final sessionId = p['session_id'] as String;

  // Query attendances for that session
  final result = db.select(
    '''
    SELECT user_id, timestamp
      FROM attendances
     WHERE session_id = ?              -- ← filter by session_id
  ''',
    [sessionId],
  );

  // Build list of attendance JSON
  final attendList = result
      .map(
        (row) => {'user_id': row['user_id'], 'timestamp': row['timestamp']},
      )
      .toList();

  // Reply with inReplyTo automatically handled by replyTo
  m.replyTo(
      p,
      {
        'command': 'attendance_list',
        'attendances': attendList,
      },
      socket);
}

void _createSchema(Database db) {
  print('[DB] Creating schema if not exists...');
  db.execute('''
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
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      qr_primary_key TEXT  NOT NULL,
      timestamp TEXT NOT NULL,
      FOREIGN KEY(session_id) REFERENCES sessions(id),
      FOREIGN KEY(user_id) REFERENCES users(id)
    );
  ''');
  print('[DB] Schema created.');
}

String _hashPassword(String password) {
  final hash = sha256.convert(utf8.encode(password)).toString();
  print('[Auth] Hashed password: $hash');
  return hash;
}

void _handleCreateUser(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  print('[User] Creating user: ${p['id']}');
  final id = p['id'] as String;
  final name = p['name'] as String;
  final password = p['password'] as String;
  final hashed = _hashPassword(password);

  final stmt = db.prepare('''
      INSERT OR IGNORE INTO users (id,name,password) VALUES (?,?,?)
  ''');
  stmt.execute([id, name, hashed]);
  stmt.dispose();
  print('[User] User created or already exists: $id');

  m.replyTo(p, {'command': 'create_user_ack', 'id': id}, socket);
}

void _handleCreateAdmin(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  print('[Admin] Creating admin: ${p['id']}');
  final id = p['id'] as String;
  final name = p['name'] as String;
  final password = p['password'] as String;
  final hashed = _hashPassword(password);

  final stmt = db.prepare('''
      INSERT OR IGNORE INTO admins (id,name,password) VALUES (?,?,?)
  ''');
  stmt.execute([id, name, hashed]);
  stmt.dispose();
  print('[Admin] Admin created or already exists: $id');

  m.replyTo(p, {'command': 'create_admin_ack', 'id': id}, socket);
}

void _handleLogin(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  print('[Auth] Login attempt: ${p['id']}');
  final id = p['id'] as String;
  final password = p['password'] as String;
  final expectedRole = p['role'] as String;
  final hashed = _hashPassword(password);

  final result = db.select(
    '''
      SELECT id,name FROM ${expectedRole}s
      WHERE id = ? AND password = ?
      ''',
    [id, hashed],
  );

  if (result.isNotEmpty) {
    final row = result.first;
    print('[Auth] Login successful: $id');
    m.replyTo(
        p,
        {
          'command': 'login_ack',
          'status': 'success',
          'id': row['id'],
          'name': row['name'],
          'role': row['role'],
        },
        socket);
  } else {
    print('[Auth] Login failed: $id');
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

void _handleCreateSession(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  final adminId = p['admin_id'] as String;
  final code = p['code'] as String;
  final expires = p['expires'] as String;

  print('[Session] Creating session for admin $adminId with code $code');

  final stmt = db.prepare('''
      INSERT INTO sessions (id,admin_id,code,expires) VALUES (?,?,?,?)
  ''');
  stmt.execute([p['session_id'] as String, adminId, code, expires]);
  stmt.dispose();

  final sessionId = p['session_id'] as String;

  print('[Session] Session created with ID $sessionId');

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

void _handleAttendance(
  Database db,
  Map<String, dynamic> p,
  Socket socket,
  SocketManager m,
) {
  final userId = p['user_id'] as String;
  final sessionId = p['session_id'] as String; // session_id should be an int
  final now = DateTime.now();

  print(
    '[Attendance] User $userId attempting to mark attendance for session ID $sessionId',
  );

  final sel = db.select(
    '''
    SELECT code, expires FROM sessions WHERE id = ?
  ''',
    [sessionId],
  );

  if (sel.isEmpty) {
    print('[Attendance] Invalid session ID: $sessionId');
    m.replyTo(
        p,
        {
          'command': 'attendance_nok',
          'reason': 'invalid_session',
        },
        socket);
    return;
  }

  final row = sel.first;
  final expiresTs = DateTime.parse(row['expires'] as String);
  if (now.isAfter(expiresTs)) {
    print('[Attendance] Session expired at $expiresTs');
    m.replyTo(p, {'command': 'attendance_nok', 'reason': 'expired'}, socket);
    return;
  }

  final attendanceKey =
      '$sessionId-$userId'; // could use this as a unique key if needed
  final result = db.select(
    '''
    SELECT 1 FROM attendances
    WHERE session_id = ? AND user_id = ?
  ''',
    [sessionId, userId],
  );

  if (result.isNotEmpty) {
    m.replyTo(
        p,
        {
          'command': 'attendance_nok',
          'reason': 'You have already signed the attendance previously',
        },
        socket);
  } else {
    final stmt = db.prepare('''
      INSERT INTO attendances (qr_primary_key, session_id, user_id, timestamp)
      VALUES (?, ?, ?, ?)
    ''');
    stmt.execute([attendanceKey, sessionId, userId, now.toIso8601String()]);
    stmt.dispose();

    print(
      '[Attendance] Attendance recorded for user $userId in session $sessionId',
    );

    m.replyTo(
        p,
        {
          'command': 'new_attendance',
          'session_id': sessionId,
          'user_id': userId,
          'timestamp': now.toIso8601String(),
        },
        socket);
  }
}
