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
  ServerSocket? _server;
  Socket? _client;
  final _completers = <String, Completer>{};
  final _uuid = Uuid();

  /// Payload factory override if needed
  dynamic Function(Map<String, dynamic>)? payloadFactory;

  /// Start listening as a server on [address] and [port].
  Future<void> startServer({
    required InternetAddress address,
    int port = 8080,
  }) async {
    _server = await ServerSocket.bind(address, port);
    print('Listening on http://${_server?.address.address}:${_server?.port}');

    _server!.listen((client) {
      client.listen(
        (data) => _handleData(data, client),
        onDone: client.close,
        onError: (e) => print('Server socket error: $e'),
      );
    });
  }

  /// Start listening as a server on [port].
  Future<void> startHttpServer(PostgreSQLConnection db,
      {int port = 8081}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('[HTTP] Listening on port $port');

    await for (HttpRequest request in server) {
      try {
        // Check authentication
        if (!checkBasicAuth(request)) {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.headers.set(
            HttpHeaders.wwwAuthenticateHeader,
            'Basic realm="Admin Area"',
          );
          await request.response.close();
          continue;
        }
        if (request.method == 'GET' && request.uri.path == '/admins') {
          // Query admins from DB
          final results = await db.mappedResultsQuery(
            'SELECT id, name, is_approved FROM admins ORDER BY name',
          );

          // Build HTML page with a form
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
        } else if (request.method == 'POST' && request.uri.path == '/admins') {
          // Read and parse form data
          final content = await utf8.decoder.bind(request).join();
          final params = Uri.splitQueryString(content);

          // params['approved'] can be a single string or comma-separated list
          final approvedIdsRaw = params['approved'];
          final approvedIds = <String>{};
          if (approvedIdsRaw != null) {
            approvedIds.addAll(approvedIdsRaw.split(','));
          }

          // Fetch all admin ids
          final allAdminsResult =
              await db.mappedResultsQuery('SELECT id FROM admins');
          final allAdminIds =
              allAdminsResult.map((r) => r['admins']!['id']!).toList();

          // Update each admin's is_approved flag depending on checkbox presence
          for (final adminId in allAdminIds) {
            final isApproved = approvedIds.contains(adminId) ? true : false;
            await db.execute(
              'UPDATE admins SET is_approved = @isApproved WHERE id = @id',
              substitutionValues: {'isApproved': isApproved, 'id': adminId},
            );
          }

          // Redirect back to GET /admins page
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set('Location', '/admins');
          await request.response.close();
        } else {
          // 404 Not Found for others
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (e, st) {
        print('[HTTP] Error: $e\n$st');
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('Internal server error');
        await request.response.close();
      }
    }
  }

  /// Send a message and optionally await a response.
  Future<dynamic> sendMessage(
    Map<String, dynamic> message, {
    bool awaitResponse = false,
  }) {
    final id = _uuid.v4().toString();
    message['messageId'] = id;
    final jsonString = jsonEncode(message);
    final data = utf8.encode(jsonString);
    _client?.add(data);
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
    Socket sender, {
    bool awaitResponse = false,
  }) {
    final id = _uuid.v4();
    message['messageId'] = id;
    sender.add(utf8.encode(jsonEncode(message)));
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
    Socket socket,
  ) {
    final replyId = request['messageId'];
    if (replyId != null) {
      response['inReplyTo'] = replyId;
    }
    socket.add(utf8.encode(jsonEncode(response)));
  }

  /// Internal handler for incoming data.
  void _handleData(Uint8List data, Socket socket) {
    final raw = utf8.decode(data);
    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;

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
  void Function(dynamic payload, Socket socket)? processPayload;

  /// Gracefully close sockets.
  Future<void> dispose() async {
    await _client?.close();
    await _server?.close();
  }
}
