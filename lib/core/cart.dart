// Pure cart + checkout logic (no Firebase) — fully unit-testable.

class CartLine {
  CartLine({required this.id, required this.name, required this.price, this.qty = 1});
  final String id;
  final String name;
  final double price;
  int qty;

  double get total => price * qty;
}

class Cart {
  final Map<String, CartLine> _lines = {};

  List<CartLine> get lines => _lines.values.toList();
  bool get isEmpty => _lines.isEmpty;
  int get itemCount => _lines.values.fold(0, (n, l) => n + l.qty);
  double get subtotal => _lines.values.fold(0.0, (n, l) => n + l.total);

  /// Cash on delivery only in v1 — no shipping fee is charged here; the
  /// total the customer sees is exactly the sum of the items.
  double get total => subtotal;

  void add(String id, String name, double price) {
    final line = _lines[id];
    if (line == null) {
      _lines[id] = CartLine(id: id, name: name, price: price);
    } else {
      line.qty += 1;
    }
  }

  void setQty(String id, int qty) {
    if (qty <= 0) {
      _lines.remove(id);
    } else {
      final line = _lines[id];
      if (line != null) line.qty = qty;
    }
  }

  void clear() => _lines.clear();
}

/// Validates the COD checkout form. Returns an Arabic error, or null if OK.
String? validateCheckout({
  required String name,
  required String phone,
  required String address,
  required bool cartEmpty,
}) {
  if (cartEmpty) return 'السلة فاضية';
  if (name.trim().isEmpty) return 'اكتب اسمك';
  if (phone.trim().isEmpty) return 'اكتب رقم الموبايل';
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 10) return 'رقم الموبايل مش كامل';
  if (address.trim().isEmpty) return 'اكتب العنوان';
  return null;
}
