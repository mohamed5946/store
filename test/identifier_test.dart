import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/identifier.dart';

void main() {
  test('Egypt phone normalization', () {
    expect(normalizeEgyptPhone('01557887719'), '201557887719');
    expect(normalizeEgyptPhone('+201557887719'), '201557887719');
    expect(normalizeEgyptPhone('00201557887719'), '201557887719');
    expect(normalizeEgyptPhone('1557887719'), '201557887719');
    expect(normalizeEgyptPhone('012345'), isNull);
    expect(normalizeEgyptPhone('abc'), isNull);
  });

  test('phone lookup key is stable and hex', () {
    final a = phoneLookupKey('201557887719');
    final b = phoneLookupKey('201557887719');
    expect(a, b);
    expect(a.length, 64);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
    expect(phoneLookupKey('201000000000'), isNot(a));
  });

  test('identifier kinds', () {
    expect(resolveIdentifierKind('a@b.com'), IdentifierKind.email);
    expect(resolveIdentifierKind('01557887719'), IdentifierKind.phone);
    expect(resolveIdentifierKind('not-an-id'), IdentifierKind.invalid);
    expect(resolveIdentifierKind('a@b'), IdentifierKind.invalid);
  });

  test('sign-in validation', () {
    expect(validateSignIn('', '123456'), isNotNull);
    expect(validateSignIn('a@b.com', ''), isNotNull);
    expect(validateSignIn('a@b.com', '123'), isNotNull);
    expect(validateSignIn('a@b.com', '123456'), isNull);
    expect(validateSignIn('01557887719', '123456'), isNull);
  });
}
