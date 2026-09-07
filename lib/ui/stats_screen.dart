import 'package:flutter/material.dart';
import '../state/pharmacy_controller.dart';
import '../domain/medicine.dart';
import 'design.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.controller});
  final PharmacyController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final stats = controller.stats;
      return ListView(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 30),
        children: [
          Text(
            'Inventory Calculator',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'One inventory. Every number, connected.',
            style: TextStyle(color: muted, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Surface(
            color: ink,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ON-HAND INVENTORY VALUE',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.5,
                    color: Color(0xFFBDD0C4),
                  ),
                ),
                const SizedBox(height: 18),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    money(stats.onHandValue),
                    style: const TextStyle(
                      fontSize: 37,
                      letterSpacing: -1,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '${stats.valuedEntries} entries with a known quantity and unit price',
                  style: const TextStyle(
                    color: Color(0xFFC5D8CC),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${stats.unvaluedEntries} entries excluded because quantity or price is missing.',
                  style: const TextStyle(color: lime, fontSize: 12),
                ),
              ],
            ),
          ),
          const SectionHeading('What is in your pharmacy'),
          LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth > 600
                  ? 4
                  : MediaQuery.textScalerOf(context).scale(14) > 22
                  ? 1
                  : 2;
              final values = [
                (
                  'Medicines',
                  '${stats.uniqueMedicines}',
                  'Unique name + strength + form',
                  Icons.medication_outlined,
                ),
                (
                  'Stock entries',
                  '${stats.stockEntries}',
                  'Includes sold and expired',
                  Icons.inventory_2_outlined,
                ),
                (
                  'Unique salts',
                  '${stats.uniqueSalts}',
                  '${stats.missingSalt} entries without salt',
                  Icons.science_outlined,
                ),
                (
                  'Known units',
                  '${stats.knownUnits}',
                  '${stats.unknownQuantity} entries with unknown quantity',
                  Icons.widgets_outlined,
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: values
                    .map(
                      (v) => SizedBox(
                        width: (c.maxWidth - 12 * (columns - 1)) / columns,
                        child: Surface(
                          padding: const EdgeInsets.all(17),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(v.$4, color: green),
                              const SizedBox(height: 14),
                              Text(
                                v.$2,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineMedium,
                              ),
                              Text(
                                v.$1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                v.$3,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SectionHeading('Stock by medicine form'),
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
              'Units use the quantity you entered, such as tablets, bottles or strips. These are stock counts, not dose counts.',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
          if (stats.byForm.isEmpty)
            const Surface(child: Text('Form counts appear as you add stock.')),
          ...stats.byForm.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Surface(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF1E3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        entry.key == 'Syrup'
                            ? Icons.water_drop_outlined
                            : Icons.medication_outlined,
                        color: green,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '${entry.value.records} stock entries · ${entry.value.unknownQuantity} unknown quantities',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${entry.value.units}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeading('Keep an eye on'),
          Surface(
            color: const Color(0xFFFBECE8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Expired stock value',
                  style: TextStyle(color: red, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  money(stats.expiredValue),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Included in on-hand value above. Review this stock separately.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Surface(
            color: const Color(0xFFFFF2D5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Value of stock marked sold',
                  style: TextStyle(color: amber, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  money(controller.snapshot.soldValue),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Estimate from saved quantity × unit price when marked sold. This is not confirmed sales revenue. ${controller.snapshot.unknownSold} marked-sold events had missing values.',
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
