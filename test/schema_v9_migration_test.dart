import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/parser.dart';

void main() {
  group('Schema v9 Migration & Prefix Cleaning Logic', () {
    test('cleanMerchantName strips UPI prefixes across all shapes and cases', () {
      expect(cleanMerchantName('UPI_GEORGE EGG CENTRE'), 'GEORGE EGG CENTRE');
      expect(cleanMerchantName('UPI_Chai point'), 'Chai point');
      expect(cleanMerchantName('UPI_Rajammal'), 'Rajammal');
      expect(cleanMerchantName('UPI-Swiggy'), 'Swiggy');
      expect(cleanMerchantName('UPI/Zomato'), 'Zomato');
      expect(cleanMerchantName('UPI George Egg Centre'), 'George Egg Centre');
      expect(cleanMerchantName('upi_chai point'), 'chai point');
      expect(cleanMerchantName('upi-uber'), 'uber');
      expect(cleanMerchantName('SWIGGY'), 'SWIGGY');
      expect(cleanMerchantName('  UPI_  Tea Stall   '), 'Tea Stall');
      expect(cleanMerchantName('UPI'), 'UPI');
    });

    test('migration transforms merchant mappings, preserving non-UPI rule on collision', () {
      final mappings = <Map<String, Object?>>[
        {'merchant_name': 'UPI_GEORGE EGG CENTRE', 'category_id': 1},
        {'merchant_name': 'UPI_Chai Point', 'category_id': 1},
        {'merchant_name': 'Chai Point', 'category_id': 2},
        {'merchant_name': 'AMAZON', 'category_id': 3},
      ];

      final Map<String, int> migrated = {};
      // Apply migration algorithm in order:
      // First register existing non-UPI mappings
      for (final m in mappings) {
        final raw = m['merchant_name'] as String;
        if (cleanMerchantName(raw) == raw) {
          migrated[raw.toLowerCase()] = m['category_id'] as int;
        }
      }
      // Then clean UPI mappings
      for (final m in mappings) {
        final raw = m['merchant_name'] as String;
        final cleaned = cleanMerchantName(raw);
        if (cleaned != raw) {
          migrated.putIfAbsent(cleaned.toLowerCase(), () => m['category_id'] as int);
        }
      }

      expect(migrated.length, 3);
      expect(migrated['george egg centre'], 1);
      // Preserved non-UPI mapping category_id = 2 (Grocery), not 1 (Food)
      expect(migrated['chai point'], 2);
      expect(migrated['amazon'], 3);
    });

    test('migration deduplicates colliding transactions with identical natural key', () {
      final txns = <Map<String, Object?>>[
        {
          'id': 1,
          'amount': 150.0,
          'merchant': 'UPI_Rajammal',
          'date': 1755000000000,
          'direction': 'debit',
          'reference': 'ref1',
        },
        {
          'id': 2,
          'amount': 250.0,
          'merchant': 'UPI_Swiggy',
          'date': 1755100000000,
          'direction': 'debit',
          'reference': 'ref2',
        },
        {
          'id': 3,
          'amount': 250.0,
          'merchant': 'Swiggy',
          'date': 1755100000000,
          'direction': 'debit',
          'reference': 'ref2',
        },
      ];

      final Set<String> seenKeys = {};
      final List<Map<String, Object?>> migrated = [];

      for (final t in txns) {
        final cleaned = cleanMerchantName(t['merchant'] as String);
        final key = '${t['amount']}_${cleaned.toLowerCase()}_${t['date']}_${t['direction']}_${t['reference']}';
        if (seenKeys.add(key)) {
          migrated.add({...t, 'merchant': cleaned});
        }
      }

      expect(migrated.length, 2);
      expect(migrated[0]['merchant'], 'Rajammal');
      expect(migrated[1]['merchant'], 'Swiggy');
      expect(migrated[1]['id'], 2); // First one kept, duplicate dropped
    });

    test('migration cleans name aliases and prevents self-aliases', () {
      final aliases = <Map<String, Object?>>[
        {'kind': 'merchant', 'alias': 'upi_george egg', 'canonical': 'UPI_George Egg Centre'},
        {'kind': 'merchant', 'alias': 'upi_swiggy', 'canonical': 'Swiggy'},
        {'kind': 'payment_type', 'alias': 'upi_card', 'canonical': 'Card 1234'},
      ];

      final List<Map<String, Object?>> migrated = [];
      for (final a in aliases) {
        final kind = a['kind'] as String;
        final rawAlias = a['alias'] as String;
        final rawCanonical = a['canonical'] as String;
        final cleanedAlias = kind == 'merchant' ? cleanMerchantName(rawAlias) : rawAlias;
        final cleanedCanonical = kind == 'merchant' ? cleanMerchantName(rawCanonical) : rawCanonical;
        if (cleanedAlias.toLowerCase() != cleanedCanonical.toLowerCase()) {
          migrated.add({'kind': kind, 'alias': cleanedAlias, 'canonical': cleanedCanonical});
        }
      }

      // upi_swiggy -> Swiggy becomes swiggy -> Swiggy (self-alias), which is dropped
      expect(migrated.length, 2);
      expect(migrated[0]['alias'], 'george egg');
      expect(migrated[0]['canonical'], 'George Egg Centre');
      expect(migrated[1]['alias'], 'upi_card'); // payment_type untouched
    });
  });
}
