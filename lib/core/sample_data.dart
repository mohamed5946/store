// Sample catalog — placeholder content so Mohamed can try everything and
// replace it from the app. His real products are not ready yet.

class SampleCategory {
  const SampleCategory(this.id, this.name);
  final String id;
  final String name;
}

class SampleProduct {
  const SampleProduct(this.id, this.name, this.price, this.categoryId, this.description);
  final String id;
  final String name;
  final double price;
  final String categoryId;
  final String description;
}

const List<SampleCategory> sampleCategories = <SampleCategory>[
  SampleCategory('cat-care', 'العناية'),
  SampleCategory('cat-electronics', 'إلكترونيات'),
  SampleCategory('cat-home', 'المنزل'),
];

const List<SampleProduct> sampleProducts = <SampleProduct>[
  SampleProduct('p1', 'كريم مرطب طبيعي', 145, 'cat-care', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
  SampleProduct('p2', 'سيروم للبشرة', 220, 'cat-care', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
  SampleProduct('p3', 'سماعة لاسلكية', 650, 'cat-electronics', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
  SampleProduct('p4', 'شاحن سريع', 280, 'cat-electronics', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
  SampleProduct('p5', 'مصباح مكتب', 390, 'cat-home', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
  SampleProduct('p6', 'منظم مكتب خشبي', 310, 'cat-home', 'منتج تجريبي — استبدله من برنامج الأدمن.'),
];

const String sampleBrandName = 'متجري';
