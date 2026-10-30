// Guard for Spark-only product images: images live as base64 inside the
// Firestore product doc (Firebase Storage needs Blaze billing, which is
// forbidden here), so a strict size cap keeps docs safely under the 1 MiB
// Firestore document limit. Pure logic — unit-testable.
class ImageGuard {
  /// Max base64 characters (~525 KB of image bytes). Anything bigger is
  /// refused loudly, never silently downscaled into unreadability.
  static const int maxBase64Chars = 700000;

  /// Returns an Arabic error message when the image is too big, else null.
  static String? checkSize(String base64) {
    if (base64.length > maxBase64Chars) {
      return 'الصورة كبيرة أوي — اختار صورة أصغر أو حط لينك صورة بدلها';
    }
    return null;
  }

  /// Rough decoded byte size of a base64 string (for display only).
  static int approxBytes(String base64) => (base64.length * 3) ~/ 4;
}
