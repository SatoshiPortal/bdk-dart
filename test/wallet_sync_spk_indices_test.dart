import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

import 'test_constants.dart';

Wallet _createWallet() => Wallet(
  descriptor: buildBip84Descriptor(Network.testnet),
  changeDescriptor: buildBip84ChangeDescriptor(Network.testnet),
  network: Network.testnet,
  persister: Persister.newInMemory(),
  lookahead: defaultLookahead,
);

void main() {
  group('Wallet.startSyncWithSpkIndices', () {
    late Wallet wallet;

    setUp(() {
      wallet = _createWallet();
      wallet.revealNextAddress(keychain: KeychainKind.external_);
      wallet.revealNextAddress(keychain: KeychainKind.external_);
    });

    test('builds a request for revealed external indices', () {
      final builder = wallet.startSyncWithSpkIndices(
        externalIndices: [0, 1],
        internalIndices: [],
      );

      expect(builder.build(), isA<SyncRequest>());
    });

    test('rejects an index that has not been revealed', () {
      expect(
        () => wallet.startSyncWithSpkIndices(
          externalIndices: [2],
          internalIndices: [],
        ),
        throwsA(
          isA<NotRevealedSpkIndexException>()
              .having((e) => e.keychain, 'keychain', KeychainKind.external_)
              .having((e) => e.index, 'index', 2)
              .having((e) => e.lastRevealed, 'lastRevealed', 1),
        ),
      );
    });

    test('rejects a request without any index', () {
      expect(
        () => wallet.startSyncWithSpkIndices(
          externalIndices: [],
          internalIndices: [],
        ),
        throwsA(isA<NoSpksRequestedSpkIndexException>()),
      );
    });

    test('rejects a keychain without revealed addresses', () {
      expect(
        () => wallet.startSyncWithSpkIndices(
          externalIndices: [0],
          internalIndices: [0],
        ),
        throwsA(
          isA<NoneRevealedSpkIndexException>().having(
            (e) => e.keychain,
            'keychain',
            KeychainKind.internal,
          ),
        ),
      );
    });
  });
}
