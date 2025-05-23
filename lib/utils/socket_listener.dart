import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:postgres/postgres.dart';

const String authUser = 'VickyE2';
const String authPass = 'ThisIsAV3RYL0ngP4ssw0rd';

bool checkBasicAuth(HttpRequest request) {
  final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
  if (authHeader == null || !authHeader.startsWith('Basic ')) return false;

  final encoded = authHeader.substring(6);
  final decoded = utf8.decode(base64.decode(encoded));
  final parts = decoded.split(':');
  if (parts.length != 2) return false;

  return parts[0] == authUser && parts[1] == authPass;
}

String _log(String level, String message) {
  final time = DateTime.now().toIso8601String();
  return '[$time] [$level] $message';
}

class SocketManager {
  HttpServer? _server;
  final _completers = <String, Completer>{};

  dynamic Function(Map<String, dynamic>)? payloadFactory;

  Future<void> startServer(PostgreSQLConnection db, int port) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print(_log('INFO', 'Server listening on port $port'));

    await for (HttpRequest request in _server!) {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          print(_log('INFO',
              'WebSocket client connected from ${request.connectionInfo?.remoteAddress.address}'));
          _handleWebSocket(socket);
        } else if (request.uri.path == '/admins') {
          if (!checkBasicAuth(request)) {
            print(_log('WARN',
                'Unauthorized access attempt to /admins from ${request.connectionInfo?.remoteAddress.address}'));
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="Admin Area"',
            );
            await request.response.close();
            continue;
          }

          if (request.method == 'GET') {
            print(_log('INFO',
                'Serving /admins GET request from ${request.connectionInfo?.remoteAddress.address}'));
            await _serveAdminsPage(request, db);
          } else if (request.method == 'POST') {
            print(_log('INFO',
                'Processing /admins POST request from ${request.connectionInfo?.remoteAddress.address}'));
            await _handleAdminsApproval(request, db);
          } else {
            print(_log(
                'WARN', 'Method not allowed: ${request.method} at /admins'));
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
          }
        } else {
          print(_log('WARN',
              '404 Not Found for ${request.method} ${request.uri.path} from ${request.connectionInfo?.remoteAddress.address}'));
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (e, st) {
        print(_log('ERROR', '[HTTP] Error: $e\n$st'));
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('Internal server error');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  void _handleWebSocket(WebSocket socket) {
    socket.listen(
      (data) {
        if (data is String) {
          print(_log('DEBUG', 'Received text data from WebSocket client'));
          _handleData(data, socket);
        } else if (data is Uint8List) {
          print(_log('DEBUG', 'Received binary data from WebSocket client'));
          _handleData(utf8.decode(data), socket);
        }
      },
      onDone: () => print(_log('INFO', 'WebSocket client disconnected')),
      onError: (e) => print(_log('ERROR', 'WebSocket error: $e')),
    );
  }

  Future<void> _serveAdminsPage(
      HttpRequest request, PostgreSQLConnection db) async {
    final results = await db.mappedResultsQuery(
      'SELECT id, name, is_approved FROM admins ORDER BY name',
    );
    print(_log('DEBUG', 'Fetched admins list from DB for /admins page'));

    final buffer = StringBuffer();
    buffer.writeln('<html><body>');
    buffer.writeln('<h1>Admin Approval List</h1>');
    buffer.writeln('<form method="POST" action="/admins">');

    for (var row in results) {
      final admin = row['admins']!;
      final id = admin['id']!;
      final name = admin['name']!;
      final approved = (admin['is_approved'] == true) ? 'checked' : '';
      buffer.writeln(
          '<input type="checkbox" name="approved" value="$id" $approved> $name<br>');
    }

    buffer.writeln('<br><button type="submit">Save</button>');
    buffer.writeln('</form></body></html>');

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(buffer.toString());
    await request.response.close();
    print(_log('INFO',
        'Served /admins page to ${request.connectionInfo?.remoteAddress.address}'));
  }

  Future<void> _handleAdminsApproval(
      HttpRequest request, PostgreSQLConnection db) async {
    final content = await utf8.decoder.bind(request).join();
    print(_log('DEBUG', 'Received admin approval form submission: $content'));
    final params = Uri.splitQueryString(content);

    final approvedRaw = params['approved'];
    final approvedIds = <String>{};
    if (approvedRaw != null) {
      approvedIds.addAll(approvedRaw.split(','));
    }

    final allAdminsResult =
        await db.mappedResultsQuery('SELECT id FROM admins');
    final allAdminIds =
        allAdminsResult.map((r) => r['admins']!['id']!).toList();

    for (final adminId in allAdminIds) {
      final isApproved = approvedIds.contains(adminId) ? true : false;
      await db.execute(
        'UPDATE admins SET is_approved = @isApproved WHERE id = @id',
        substitutionValues: {'isApproved': isApproved, 'id': adminId},
      );
      print(_log('DEBUG', 'Admin $adminId approval set to $isApproved'));
    }

    request.response
      ..statusCode = HttpStatus.seeOther
      ..headers.set('Location', '/admins');
    await request.response.close();
    print(_log('INFO', 'Processed admin approvals and redirected'));
  }

  void replyTo(
    Map<String, dynamic> request,
    Map<String, dynamic> response,
    WebSocket socket,
  ) {
    final replyId = request['messageId'];
    if (replyId != null) {
      response['inReplyTo'] = replyId;
    }
    final data = jsonEncode(response);
    print(_log('INFO', 'Sending reply to messageId=$replyId: $data'));
    socket.add(data);
  }

  void _handleData(String data, WebSocket socket) {
    try {
      print(_log('DEBUG', 'Received data: $data'));
      final payload = jsonDecode(data) as Map<String, dynamic>;

      if (payload.containsKey('inReplyTo')) {
        final replyId = payload['inReplyTo'] as String;
        final completer = _completers.remove(replyId);
        if (completer != null) {
          completer.complete(payload);
          print(_log('INFO', 'Completed future for messageId=$replyId'));
        } else {
          print(_log('WARN', 'No completer found for messageId=$replyId'));
        }
        return;
      }

      if (processPayload != null) {
        processPayload!(payload, socket);
      } else {
        print(_log(
            'WARN', 'No processPayload function defined to handle message'));
      }
    } catch (e) {
      print(_log('ERROR', 'Invalid JSON received: $e'));
    }
  }

  void Function(dynamic payload, WebSocket socket)? processPayload;

  Future<void> dispose() async {
    await _server?.close();
    print(_log('INFO', 'SocketManager disposed and connections closed'));
  }
}
