import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

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

  /// Connect to a server at [host] and [port].
  Future<void> connectToServer(String host, int port) async {
    _client = await Socket.connect(host, port);
    _client!.listen(
      (data) => _handleData(data, _client!),
      onDone: _client!.close,
      onError: (e) => print('Client socket error: $e'),
    );
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
