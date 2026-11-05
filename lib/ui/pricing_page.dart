import 'package:flutter/material.dart';

import '../main.dart';
import '../price_db.dart';
import '../state.dart';

/// Full-page editor for the price database (the DATA sheet).
/// Edits propagate to every BOQ line that still tracks the material
/// (lines whose unit price was hand-edited are left untouched).
class PricingPage extends StatefulWidget {
  const PricingPage({super.key});

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  final _search = TextEditingController();
  String _category = 'ALL';

  List<String> get _categories {
    final cats = est.priceDb.map((m) => m.category).toSet().toList()..sort();
    return ['ALL', ...cats];
  }

  List<MaterialPrice> get _filtered {
    final q = _search.text.trim().toUpperCase();
    return est.priceDb.where((m) {
      if (_category != 'ALL' && m.category != _category) return false;
      return q.isEmpty ||
          m.name.toUpperCase().contains(q) ||
          m.category.toUpperCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      body: Column(
        children: [
          _topBar(items.length),
          const Divider(height: 1),
          _columnHeader(),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'No materials match.',
                      style: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  )
                : ListenableBuilder(
                    listenable: est,
                    builder: (_, _) => ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 16),
                      itemBuilder: (_, i) =>
                          _PriceRow(m: items[i], onEdit: _editMaterial),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editMaterial(null),
        icon: const Icon(Icons.add),
        label: const Text('Add material'),
      ),
    );
  }

  Widget _topBar(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.white,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Back',
          ),
          const SizedBox(width: 4),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PRICE DATABASE',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
              Text(
                'Labor cost = 30% of material price (same as DATA sheet)',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
          const SizedBox(width: 20),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search material…',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: _categories
                  .map(
                    (c) => DropdownMenuItem(
                      value: c,
                      child: Text(
                        c,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? 'ALL'),
            ),
          ),
          const Spacer(),
          Text(
            '$count items',
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _confirmReset,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text(
              'Reset to defaults',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnHeader() {
    Widget h(String t, [double? w]) => w == null
        ? Expanded(flex: 3, child: Text(t, style: _hs))
        : SizedBox(
            width: w,
            child: Text(t, style: _hs, textAlign: TextAlign.right),
          );
    return Container(
      color: const Color(0xFFF1F5F9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          h('MATERIAL / WORK ITEM'),
          h('CATEGORY', 220),
          h('UNIT', 70),
          h('MATERIAL ₱', 110),
          h('LABOR ₱ (30%)', 110),
          h('', 76),
        ],
      ),
    );
  }

  static const _hs = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w800,
    color: Color(0xFF64748B),
  );

  void _editMaterial(MaterialPrice? m) async {
    final name = TextEditingController(text: m?.name ?? '');
    final cat = TextEditingController(
      text: m?.category ?? 'GENERAL REQUIREMENTS',
    );
    final unit = TextEditingController(text: m?.unit ?? 'pcs');
    final price = TextEditingController(
      text: m == null ? '' : m.price.toStringAsFixed(2),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(m == null ? 'Add material' : 'Edit material'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cat,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  hintText: 'e.g. CONCRETING WORKS',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Material price',
                        prefixText: '₱ ',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;

    final p = double.tryParse(price.text) ?? 0;
    if (m == null) {
      est.addMaterial(
        MaterialPrice(name.text.trim(), cat.text.trim(), unit.text.trim(), p),
      );
    } else {
      final oldName = m.name;
      m.name = name.text.trim();
      m.category = cat.text.trim();
      m.unit = unit.text.trim();
      m.price = p;
      est.applyMaterialEdit(m, oldName);
    }
    setState(() {});
  }

  void _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset price database?'),
        content: const Text(
          'This restores the original prices from the template DATA sheet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      est.resetPriceDb();
      setState(() {});
    }
  }
}

class _PriceRow extends StatelessWidget {
  final MaterialPrice m;
  final void Function(MaterialPrice) onEdit;
  const _PriceRow({required this.m, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onEdit(m),
      hoverColor: const Color(0x0A1E4976),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                m.name,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            SizedBox(
              width: 220,
              child: Text(
                m.category,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ),
            SizedBox(
              width: 70,
              child: Text(
                m.unit,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                moneyFmt.format(m.price),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                moneyFmt.format(m.price * est.laborRate),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ),
            SizedBox(
              width: 76,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: Color(0xFF64748B),
                    ),
                    onPressed: () => onEdit(m),
                    splashRadius: 14,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: Color(0xFFEF9A9A),
                    ),
                    onPressed: () => est.removeMaterial(m),
                    splashRadius: 14,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
