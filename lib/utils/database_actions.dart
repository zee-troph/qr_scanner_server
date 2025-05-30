import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
import 'package:postgres/postgres.dart';
import 'dart:convert';
import 'socket_listener.dart';
import 'package:pdf/widgets.dart' as pw;

void prepareServer(PostgreSQLConnection db, int port) async {
  print('[SERVER] Preparing server...');
  final manager = SocketManager();
  manager.processPayload = (payload, socket) {
    print('[Payload] Received: $payload');
    if (payload is! Map<String, dynamic> || !payload.containsKey('command'))
      return;
    switch (payload['command'] as String) {
      case 'ping':
        manager.replyTo(payload, {'command': 'pong', 'status': 'ok'}, socket);
        break;
      case 'create_user':
        _handleCreateUser(db, payload, socket, manager);
        break;
      case 'gen_attendance_pdf':
        _handleGeneratePdf(db, payload, socket, manager);
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
  await manager.startServer(
    db,
    port,
  );
}

/// --- UTILITY FUNCTIONS ---

String _hashPassword(String password) {
  final hash = sha256.convert(utf8.encode(password)).toString();
  print('[Auth] Hashed password: $hash');
  return hash;
}

/// --- DB SCHEMA CREATION ---

Future<void> createSchema(PostgreSQLConnection db) async {
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
      password TEXT NOT NULL,
      is_approved BOOLEAN DEFAULT FALSE
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      admin_id TEXT NOT NULL,
      code TEXT NOT NULL,
      expires TIMESTAMPTZ NOT NULL,
      FOREIGN KEY(admin_id) REFERENCES admins(id)
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
  WebSocket socket,
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
  WebSocket socket,
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
  WebSocket socket,
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
  WebSocket socket,
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

  m.replyTo(
      p,
      {
        'command': 'create_admin_ack',
        'message': "Your request has been sent :D",
      },
      socket);
}

Future<void> _handleGeneratePdf(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  WebSocket socket,
  SocketManager m,
) async {
  final sessionId = p['session_id'] as String;

  // Fetch session info
  final sessionInfoQuery = await db.query('''
    SELECT s.code, s.expires, a.name
    FROM sessions s
    JOIN admins a ON a.id = s.admin_id
    WHERE s.id = @sessionId
  ''', substitutionValues: {'sessionId': sessionId.trim()});

  if (sessionInfoQuery.isEmpty) {
    m.replyTo(
        p, {'command': 'pdf_error', 'error': 'Session not found'}, socket);
    return;
  }

  final row = sessionInfoQuery[0];
  final sessionInfo = {
    'code': row[0] ?? 'UNKNOWN',
    'expires': row[1]?.toString() ?? 'UNKNOWN',
    'admin_name': row[2] ?? 'UNKNOWN',
  };

  // Get attendances
  final result = await db.query('''
    SELECT a.user_id, a.qr_primary_key, a.timestamp, u.name
    FROM attendances a
    JOIN users u ON u.id = a.user_id
    WHERE a.session_id = @sessionId
  ''', substitutionValues: {'sessionId': sessionId});

  final attendanceData = result
      .map((row) => {
            'user_id': row[0] ?? 'UNKNOWN',
            'qr_primary_key': row[1] ?? 'UNKNOWN',
            'timestamp': row[2]?.toString() ?? 'UNKNOWN',
            'name': row[3] ?? 'UNKNOWN',
          })
      .toList();

  final pdf = pw.Document();

  pdf.addPage(
    pw.MultiPage(
      footer: (context) => pw.Container(
        alignment: pw.Alignment.center,
        margin: const pw.EdgeInsets.only(top: 20),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Generated by Attendance System',
              style: pw.TextStyle(
                fontSize: 12,
                color: PdfColors.grey,
                fontStyle: pw.FontStyle.italic,
              ),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: pw.TextStyle(
                fontSize: 12,
                color: PdfColors.grey,
                fontStyle: pw.FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
      build: (context) {
        final headerStyle = pw.TextStyle(
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        );

        final cellStyle = pw.TextStyle(
          fontSize: 10,
        );

        final tableHeaders = ['User ID', 'Name', 'Matric Number', 'Timestamp'];

        final tableRows = <pw.TableRow>[
          // Header row
          pw.TableRow(
            decoration: pw.BoxDecoration(color: PdfColors.blueGrey800),
            children: tableHeaders
                .map((header) => pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text(header, style: headerStyle),
                    ))
                .toList(),
          ),

          // Data rows with alternating colors
          for (int i = 0; i < attendanceData.length; i++)
            pw.TableRow(
              decoration: pw.BoxDecoration(
                color: i.isEven ? PdfColors.grey100 : PdfColors.white,
              ),
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Text('${attendanceData[i]['user_id']}',
                      style: cellStyle),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child:
                      pw.Text('${attendanceData[i]['name']}', style: cellStyle),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Text(
                    '${attendanceData[i]['qr_primary_key'].toString().replaceAll(sessionId, "")}',
                    style: cellStyle,
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Text(
                    '${attendanceData[i]['timestamp']}',
                    style: cellStyle,
                  ),
                ),
              ],
            ),
        ];

        return [
          pw.Text(
            'Attendance Report',
            style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 12),
          pw.Text('Session Info:', style: pw.TextStyle(fontSize: 18)),
          pw.Text('Code: ${sessionInfo['code']}'),
          pw.Text('Admin: ${sessionInfo['admin_name']}'),
          pw.Text('Expires: ${sessionInfo['expires']}'),
          pw.SizedBox(height: 20),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey),
            columnWidths: {
              0: const pw.FlexColumnWidth(2),
              1: const pw.FlexColumnWidth(3),
              2: const pw.FlexColumnWidth(3),
              3: const pw.FlexColumnWidth(4),
            },
            children: tableRows,
          ),
        ];
      },
    ),
  );

  final bytes = await pdf.save();
  const chunkSize = 16000; // 16 KB
  final totalChunks = (bytes.length / chunkSize).ceil();
  final fileId = sessionId; // can be UUID or sessionId

  for (var i = 0; i < totalChunks; i++) {
    final start = i * chunkSize;
    final end =
        (start + chunkSize < bytes.length) ? start + chunkSize : bytes.length;
    final chunkBytes = bytes.sublist(start, end);
    final chunk = base64.encode(chunkBytes);

    m.replyTo(
        p,
        {
          'command': 'pdf_chunk',
          'file_id': fileId,
          'chunk_index': i,
          'total_chunks': totalChunks,
          'data': chunk,
        },
        socket);
  }

  // Optionally send a final signal
  m.replyTo(
      p,
      {
        'command': 'pdf_done',
        'file_id': fileId,
        'file_name': 'attendance_report_$sessionId.pdf',
      },
      socket);
}

Future<void> _handleLogin(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  WebSocket socket,
  SocketManager m,
) async {
  final id = p['id'] as String;
  final password = p['password'] as String;
  final role = p['role'] as String;
  final hashed = _hashPassword(password);

  // Query user/admin info by id and password
  final result = await db.mappedResultsQuery(
    '''
    SELECT id, name FROM ${role}s
    WHERE id = @id AND password = @password
    ''',
    substitutionValues: {'id': id, 'password': hashed},
  );

  if (result.isEmpty) {
    // User not found or password mismatch
    m.replyTo(
        p,
        {
          'command': 'login_ack',
          'status': 'failed',
          'reason': 'Your credentials are invalid or user not found',
        },
        socket);
    return;
  }

  // If role is admin, check if approved
  if (role == 'admin') {
    final approvalResult = await db.mappedResultsQuery(
      'SELECT is_approved FROM admins WHERE id = @id',
      substitutionValues: {'id': id},
    );

    if (approvalResult.isEmpty) {
      m.replyTo(
          p,
          {
            'command': 'login_ack',
            'status': 'failed',
            'reason': 'Admin user not found',
          },
          socket);
      return;
    }

    final isApproved = approvalResult.first['admins']?['is_approved'];
    if (isApproved == null || isApproved == false) {
      m.replyTo(
          p,
          {
            'command': 'login_ack',
            'status': 'failed',
            'reason': 'You are not approved yet',
          },
          socket);
      return;
    }
  }

  // All checks passed, send success response
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
}

Future<void> _handleCreateSession(
  PostgreSQLConnection db,
  Map<String, dynamic> p,
  WebSocket socket,
  SocketManager m,
) async {
  final sessionId = p['session_id'] as String;
  final adminId = p['admin_id'] as String;
  final code = p['code'] as String;
  final expires = (DateTime.parse(p['expires'])).toUtc().toIso8601String();

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
  WebSocket socket,
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
          'reason': 'Invalid Session. That is not a valid Attendance QR code',
        },
        socket);
    return;
  }

  final expiresTs = DateTime.parse(sel.first['sessions']!['expires']).toUtc();
  if (DateTime.now().toUtc().isAfter(expiresTs)) {
    m.replyTo(
        p,
        {
          'command': 'attendance_nok',
          'reason': 'That Attendance has already Expired...'
        },
        socket);
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
          'reason':
              'You have already signed that attendance... You can only sign once',
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
