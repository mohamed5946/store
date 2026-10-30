// Identifier resolution for sign-in: one field accepts email OR phone.
// Same proven pattern as the sibling apps, reimplemented here.
import 'dart:convert';
import 'package:crypto/crypto.dart';

enum IdentifierKind { email, phone, invalid }

/// Normalizes an Egyptian phone to the lookup form: 12 digits starting with
/// '20' (e.g. 01557887719 -> 201557887719). Returns null when the input is
/// not a plausible Egyptian mobile number.
String? normalizeEgyptPhone(String raw) {
  var digits = raw.replaceAll(RegExp(r'[\s\-()]'), '');
  if (digits.startsWith('+')) digits = digits.substring(1);
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.length == 11 && digits.startsWith('01')) {
    return '20${digits.substring(1)}';
  }
  if (digits.length == 12 && digits.startsWith('20')) return digits;
  if (digits.length == 10 && digits.startsWith('1')) return '20$digits';
  return null;
}

/// SHA-256 hex of the normalized phone — the Firestore phones lookup key.
/// Only the hash is ever stored or queried; the raw phone never is a doc id.
String phoneLookupKey(String normalizedPhone) {
  return sha256.convert(utf8.encode(normalizedPhone)).toString();
}

IdentifierKind resolveIdentifierKind(String raw) {
  final input = raw.trim();
  if (input.contains('@')) {
    return input.contains('.') ? IdentifierKind.email : IdentifierKind.invalid;
  }
  if (normalizeEgyptPhone(input) != null) return IdentifierKind.phone;
  return IdentifierKind.invalid;
}

/// Validates a sign-in form. Returns an Arabic error message, or null if OK.
String? validateSignIn(String identifier, String password) {
  if (identifier.trim().isEmpty) return 'اكتب الإيميل أو رقم الموبايل';
  if (resolveIdentifierKind(identifier) == IdentifierKind.invalid) {
    return 'الإيميل أو رقم الموبايل مش صحيح';
  }
  if (password.isEmpty) return 'اكتب كلمة السر';
  if (password.length < 6) return 'كلمة السر لازم تكون 6 حروف على الأقل';
  return null;
}
