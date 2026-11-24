import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

import 'test_constants.dart';

// Version 2, one input spending 00…00:0, one 1 000 sat P2WPKH output.
final _rawTx = Uint8List.fromList([
  2, 0, 0, 0, //
  1, ...List.filled(32, 0), 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, //
  1, 0xe8, 0x03, 0, 0, 0, 0, 0, 0, 22, 0x00, 0x14, ...List.filled(20, 0xab), //
  0, 0, 0, 0,
]);

/// Loopback Electrum server reporting one unconfirmed transaction. It runs
/// in its own isolate because the client's
/// calls block the calling isolate until the server replies.
class _ElectrumStub {
  final Isolate _isolate;
  final SendPort _control;
  final int port;

  _ElectrumStub(this._isolate, this._control, this.port);

  static Future<_ElectrumStub> start() async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, ready.sendPort);
    final [control as SendPort, port as int] = await ready.first as List;
    return _ElectrumStub(isolate, control, port);
  }

  String get url => 'tcp://127.0.0.1:$port';

  /// Number of `blockchain.transaction.get` requests served so far.
  Future<int> transactionGets() async {
    final reply = ReceivePort();
    _control.send(reply.sendPort);
    return await reply.first as int;
  }

  void close() => _isolate.kill(priority: Isolate.immediate);

  static Future<void> _serve(SendPort ready) async {
    var transactionGets = 0;
    final hex = _rawTx.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final tx = Transaction(transactionBytes: _rawTx);
    final id = tx.computeTxid();
    final txid = id.toString();
    id.dispose();
    tx.dispose();
    const genesis =
        '01000000'
        '0000000000000000000000000000000000000000000000000000000000000000'
        '3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a'
        'dae5494dffff001d1aa4ae18';
    Object answer(Object? request) {
      if (request is List) return request.map(answer).toList();
      final call = request as Map<String, dynamic>;
      final result = switch (call['method']) {
        'server.version' => ['stub', '1.4'],
        'blockchain.headers.subscribe' => {'height': 0, 'hex': genesis},
        'blockchain.block.header' => genesis,
        'blockchain.block.headers' => {'count': 1, 'hex': genesis, 'max': 2016},
        'blockchain.scripthash.get_history' => [
          {'tx_hash': txid, 'height': 0},
        ],
        'blockchain.transaction.get' => (() {
          transactionGets++;
          return hex;
        })(),
        _ => null,
      };
      return {'jsonrpc': '2.0', 'id': call['id'], 'result': result};
    }

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(
            (line) => socket.write('${jsonEncode(answer(jsonDecode(line)))}\n'),
          );
    });
    final control = ReceivePort();
    control.listen((reply) => (reply as SendPort).send(transactionGets));
    ready.send([control.sendPort, server.port]);
  }
}

ElectrumClient _client(_ElectrumStub stub) => ElectrumClient(
  url: stub.url,
  socks5: null,
  timeout: 5,
  retry: 0,
  validateDomain: false,
);

void main() {
  group('ElectrumClient cache prefill', () {
    late _ElectrumStub stub;
    late Transaction tx;

    setUp(() async {
      stub = await _ElectrumStub.start();
      tx = Transaction(transactionBytes: _rawTx);
    });

    tearDown(() => stub.close());

    test('fetchTx downloads a transaction the client has not seen', () async {
      final client = _client(stub);
      final fetched = client.fetchTx(txid: tx.computeTxid());
      expect(fetched.computeTxid().toString(), tx.computeTxid().toString());
      expect(await stub.transactionGets(), 1);
    });

    test('populateTxCache lets fetchTx answer without a request', () async {
      final client = _client(stub);
      client.populateTxCache(txs: [tx]);
      final fetched = client.fetchTx(txid: tx.computeTxid());
      expect(fetched.computeTxid().toString(), tx.computeTxid().toString());
      expect(await stub.transactionGets(), 0);
    });

    test('populateAnchorCache accepts an anchor without a request', () async {
      final client = _client(stub);
      client.populateAnchorCache(
        anchors: [
          TxAnchor(
            txid: tx.computeTxid(),
            anchor: ConfirmationBlockTime(
              blockId: BlockId(
                height: 1,
                hash: BlockHash.fromBytes(bytes: Uint8List(32)),
              ),
              confirmationTime: 1296689202,
            ),
          ),
        ],
      );
      expect(await stub.transactionGets(), 0);
    });

    test(
      'a targeted update exposes observations before wallet apply',
      () async {
        final descriptor = buildBip84Descriptor(Network.testnet);
        addTearDown(descriptor.dispose);
        final change = buildBip84ChangeDescriptor(Network.testnet);
        addTearDown(change.dispose);
        final persister = Persister.newInMemory();
        addTearDown(persister.dispose);
        final wallet = Wallet(
          descriptor: descriptor,
          changeDescriptor: change,
          network: Network.testnet,
          persister: persister,
          lookahead: defaultLookahead,
        );
        addTearDown(wallet.dispose);
        final address = wallet.revealNextAddress(
          keychain: KeychainKind.external_,
        );
        addTearDown(address.address.dispose);
        final builder = wallet.startSyncWithSpkIndices(
          externalIndices: [address.index],
          internalIndices: [],
        );
        addTearDown(builder.dispose);
        final request = builder.build();
        addTearDown(request.dispose);
        final client = _client(stub);
        addTearDown(client.dispose);
        client.populateTxCache(txs: [tx]);
        final update = client.sync_(
          request: request,
          batchSize: 10,
          fetchPrevTxouts: false,
        );
        addTearDown(update.dispose);
        final id = tx.computeTxid();
        addTearDown(id.dispose);

        final observations = update.transactionObservations();
        expect(observations.unconfirmed, [id.toString()]);
        expect(observations.anchored, isEmpty);
        expect(observations.listed, [id.toString()]);
        expect(await stub.transactionGets(), 0);
      },
    );
  });
}
