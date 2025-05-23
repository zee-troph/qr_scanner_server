import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

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

/// A class to manage socket communication over LAN, listening and sending JSON packets,
/// and awaiting responses by message ID.
class SocketManager {
  HttpServer? _server;
  WebSocket? _client;
  final _completers = <String, Completer>{};
  final _uuid = Uuid();

  /// Payload factory override if needed
  dynamic Function(Map<String, dynamic>)? payloadFactory;

  /// Start listening as a server on [address] and [port].
  Future<void> startServer(PostgreSQLConnection db, int port) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('Server listening on port $port');

    await for (HttpRequest request in _server!) {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _handleWebSocket(socket);
        } else if (request.uri.path == '/admins') {
          if (!checkBasicAuth(request)) {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="Admin Area"',
            );
            await request.response.close();
            continue;
          }

          if (request.method == 'GET') {
            await _serveAdminsPage(request, db);
          } else if (request.method == 'POST') {
            await _handleAdminsApproval(request, db);
          } else {
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (e, st) {
        print('[HTTP] Error: $e\n$st');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('Internal server error');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  void _handleWebSocket(WebSocket socket) {
    print('WebSocket client connected');
    socket.listen(
      (data) {
        if (data is String) {
          _handleData(data, socket);
        } else if (data is Uint8List) {
          _handleData(utf8.decode(data), socket);
        }
      },
      onDone: () => print('WebSocket client disconnected'),
      onError: (e) => print('WebSocket error: $e'),
    );
  }

  Future<void> _serveAdminsPage(
      HttpRequest request, PostgreSQLConnection db) async {
    final results = await db.mappedResultsQuery(
      'SELECT id, name, is_approved FROM admins ORDER BY name',
    );

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
  }

  Future<void> _handleAdminsApproval(
      HttpRequest request, PostgreSQLConnection db) async {
    final content = await utf8.decoder.bind(request).join();
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
    }

    request.response
      ..statusCode = HttpStatus.seeOther
      ..headers.set('Location', '/admins');
    await request.response.close();
  }

  /// Send a message and optionally await a response.
  Future<dynamic> sendMessage(
    Map<String, dynamic> message, {
    bool awaitResponse = false,
  }) {
    final id = _uuid.v4().toString();
    message['messageId'] = id;
    final jsonString = jsonEncode(message);
    _client?.add(jsonString);
    if (awaitResponse) {
      final completer = Completer<dynamic>();
      _completers[id] = completer;
      return completer.future;
    } else {
      return Future.value(null);
    }
  }

  /// Send a message and optionally await a response.
  Future<dynamic> sendMessageSrv(
    Map<String, dynamic> message,
    WebSocket sender, {
    bool awaitResponse = false,
  }) {
    final id = _uuid.v4();
    message['messageId'] = id;
    sender.add(jsonEncode(message));
    if (awaitResponse) {
      final completer = Completer<dynamic>();
      _completers[id] = completer;
      return completer.future;
    } else {
      return Future.value(null);
    }
  }

  /// Reply to a message, ensuring the 'inReplyTo' field is set.
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
    print("Replying data: $data");
    socket.add(data);
  }

  /// Internal handler for incoming data.
  void _handleData(String data, WebSocket socket) {
    try {
      print("Received data: $data");
      final payload = jsonDecode(data) as Map<String, dynamic>;

      // If server sent a response to a request
      if (payload.containsKey('inReplyTo')) {
        final replyId = payload['inReplyTo'] as String;
        final completer = _completers.remove(replyId);
        completer?.complete(payload);
        return;
      }

      // Otherwise process normally
      if (processPayload != null) {
        processPayload!(payload, socket);
      }
    } catch (e) {
      print('Invalid JSON received: $e');
    }
  }

  /// Override this to handle incoming messages.
  /// To reply, include 'inReplyTo': received messageId
  void Function(dynamic payload, WebSocket socket)? processPayload;

  /// Gracefully close sockets.
  Future<void> dispose() async {
    await _client?.close();
    await _server?.close();
  }
}
