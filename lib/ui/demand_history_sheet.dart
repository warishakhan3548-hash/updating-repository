import 'package:flutter/material.dart';

import '../domain/daily_demand.dart';
import '../domain/medicine.dart';
import '../domain/stock_guidance.dart';
import '../domain/tracking.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

Future<void> showDemandHistory(
  BuildContext context,
  PharmacyController controller, {
  required String productKey,
  required String title,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .85,
    child: _DemandHistory(
      controller: controller,
      productKey: productKey,
      title: title,
    ),
  ),
);

class _DemandHistory extends StatefulWidget {
  const _DemandHistory({
    required this.controller,
    required this.productKey,
    required this.title,
  });
  final PharmacyController controller;
  final String productKey, title;
  @override
  State<_DemandHistory> createState() => _DemandHistoryState();
}

class _DemandHistoryState extends State<_DemandHistory> {
  Object? _records;
  Object? _sales;
  DateTime? _day;
  DailyDemandProfile? _demand;

  DailyDemandProfile _read() {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    if (!identical(_records, snapshot.records) ||
        !identical(_sales, snapshot.sales) ||
        _day != controller.today) {
      _demand =
          dailyDemandByProduct(
            medicines: controller.records,
            sales: controller.sales,
            today: controller.today,
          )[widget.productKey] ??
          DailyDemandAccumulator(controller.today).build();
      _records = snapshot.records;
      _sales = snapshot.sales;
      _day = controller.today;
    }
    return _demand!;
  }

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
    listenable: widget.controller,
    rebuildToken: () => (
      widget.controller.snapshot.records,
      widget.controller.snapshot.sales,
      widget.controller.today,
    ),
    builder: (context, _) {
      final demand = _read();
      final days = [
        DailySaleTotal(demand.today, demand.todayUnits),
        ...demand.days.reversed.take(29),
      ];
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'बिक्री का हिसाब',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(widget.title, style: const TextStyle(color: muted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'बंद करें',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              itemCount: days.length + 1,
              itemBuilder: (context, index) {
                if (index == 0)
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Chip(label: Text('आज ${demand.todayUnits}')),
                            Chip(label: Text('कल ${demand.yesterdayUnits}')),
                            Chip(
                              label: Text('30 दिन ${demand.unitsLast30Days}'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          demandTrendLabel(demand),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'पिछले 7 पूरे दिन: ${demand.recentWeekUnits} · उससे पहले: ${demand.previousWeekUnits}',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        if (demand.hasEstimate)
                          Text(
                            'अनुमान ≈${demand.planningUnitsPerDay.toStringAsFixed(2)} यूनिट / दिन',
                            style: const TextStyle(
                              color: primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        Text(
                          demand.reviewRequired
                              ? 'मात्रा जाँचें · रिकॉर्ड कम, अनियमित या जाँचने लायक है'
                              : '${demand.sellingDays} अलग दिनों की दर्ज बिक्री से अनुमान',
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'ऑर्डर का हिसाब: 7 दिन में सप्लाई, 30 दिन का स्टॉक। सप्लायर का समय अलग हो तो मात्रा बदलें।',
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'नीचे दर्ज यूनिट हैं। 0 = बिक्री दर्ज नहीं हुई। आज का दिन अभी पूरा नहीं है।',
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  );
                final row = days[index - 1];
                return ListTile(
                  key: ValueKey(row.day),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(index == 1 ? 'आज · अभी तक' : dateText(row.day)),
                  trailing: Text(
                    '${row.units} यूनिट',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
