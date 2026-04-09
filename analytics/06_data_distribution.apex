/**
 * ============================================================
 * METRIC: Data Distribution & Load Analysis
 * ============================================================
 *
 * Purpose:
 *   Understand data volume patterns to plan for load testing and
 *   identify peak sync periods. Shows records modified per month,
 *   distribution by stage, and hourly activity patterns.
 *
 * Metrics:
 *   records_per_month     = COUNT grouped by CALENDAR_MONTH
 *   records_per_hour      = COUNT grouped by HOUR_IN_DAY (activity pattern)
 *   records_by_stage      = COUNT grouped by StageName
 *   avg_line_items_per_opp= total_line_items / total_opportunities
 *
 * Use this data to:
 *   - Set realistic batch sizes for load tests
 *   - Identify peak sync windows for capacity planning
 *   - Understand typical data shapes for accuracy testing
 * ============================================================
 */

// --- Records modified per month (last 12 months) ---
List<AggregateResult> oppByMonth = [
    SELECT CALENDAR_MONTH(LastModifiedDate) mo,
           CALENDAR_YEAR(LastModifiedDate) yr,
           COUNT(Id) cnt
    FROM Opportunity
    WHERE LastModifiedDate >= LAST_N_MONTHS:12
    GROUP BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate)
    ORDER BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate)
];

List<AggregateResult> oliByMonth = [
    SELECT CALENDAR_MONTH(LastModifiedDate) mo,
           CALENDAR_YEAR(LastModifiedDate) yr,
           COUNT(Id) cnt
    FROM OpportunityLineItem
    WHERE LastModifiedDate >= LAST_N_MONTHS:12
    GROUP BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate)
    ORDER BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate)
];

// --- Hourly activity pattern (last 7 days) ---
List<AggregateResult> oppByHour = [
    SELECT HOUR_IN_DAY(LastModifiedDate) hr, COUNT(Id) cnt
    FROM Opportunity
    WHERE LastModifiedDate >= LAST_N_DAYS:7
    GROUP BY HOUR_IN_DAY(LastModifiedDate)
    ORDER BY HOUR_IN_DAY(LastModifiedDate)
];

// --- By Stage distribution ---
List<AggregateResult> byStage = [
    SELECT StageName, COUNT(Id) cnt, AVG(Amount) avgAmount
    FROM Opportunity
    WHERE IsDeleted = false
    GROUP BY StageName
    ORDER BY COUNT(Id) DESC
    LIMIT 20
];

// --- Line items per opportunity distribution ---
List<AggregateResult> lineItemDist = [
    SELECT OpportunityId, COUNT(Id) cnt
    FROM OpportunityLineItem
    WHERE IsDeleted = false
    GROUP BY OpportunityId
    ORDER BY COUNT(Id) DESC
    LIMIT 5000
];

// Compute distribution stats manually
Integer totalOppsWithItems = lineItemDist.size();
Integer totalItems = 0;
Integer maxItems = 0;
Map<Integer, Integer> histogram = new Map<Integer, Integer>();
for (AggregateResult ar : lineItemDist) {
    Integer cnt = (Integer) ar.get('cnt');
    totalItems += cnt;
    if (cnt > maxItems) maxItems = cnt;

    // Bucket: 1, 2-3, 4-5, 6-10, 11-20, 20+
    Integer bucket;
    if (cnt == 1) bucket = 1;
    else if (cnt <= 3) bucket = 3;
    else if (cnt <= 5) bucket = 5;
    else if (cnt <= 10) bucket = 10;
    else if (cnt <= 20) bucket = 20;
    else bucket = 99;

    Integer prev = histogram.containsKey(bucket) ? histogram.get(bucket) : 0;
    histogram.put(bucket, prev + 1);
}

// --- Output ---
System.debug('================================================================');
System.debug('  METRIC: DATA DISTRIBUTION & LOAD ANALYSIS');
System.debug('================================================================');
System.debug('');

System.debug('--- OPPORTUNITY MODIFICATIONS BY MONTH ---');
for (AggregateResult ar : oppByMonth) {
    System.debug('  ' + ar.get('yr') + '-' + String.valueOf(ar.get('mo')).leftPad(2, '0') + ': ' + ar.get('cnt') + ' records');
}

System.debug('');
System.debug('--- LINE ITEM MODIFICATIONS BY MONTH ---');
for (AggregateResult ar : oliByMonth) {
    System.debug('  ' + ar.get('yr') + '-' + String.valueOf(ar.get('mo')).leftPad(2, '0') + ': ' + ar.get('cnt') + ' records');
}

System.debug('');
System.debug('--- HOURLY ACTIVITY PATTERN (Opps, last 7 days) ---');
for (AggregateResult ar : oppByHour) {
    Integer hr = (Integer) ar.get('hr');
    Integer cnt = (Integer) ar.get('cnt');
    String bar = '';
    Integer barLen = Math.min(cnt, 50);
    for (Integer i = 0; i < barLen; i++) bar += '#';
    System.debug('  ' + String.valueOf(hr).leftPad(2, '0') + ':00  ' + bar + '  (' + cnt + ')');
}

System.debug('');
System.debug('--- OPPORTUNITY BY STAGE ---');
for (AggregateResult ar : byStage) {
    Decimal avgAmt = ar.get('avgAmount') != null ? (Decimal) ar.get('avgAmount') : 0;
    System.debug('  ' + ar.get('StageName') + ': ' + ar.get('cnt') + ' opps, avg amount: $' + avgAmt.setScale(0));
}

System.debug('');
System.debug('--- LINE ITEMS PER OPPORTUNITY DISTRIBUTION ---');
Decimal avgItemsPerOpp = totalOppsWithItems > 0
    ? Decimal.valueOf(totalItems) / totalOppsWithItems
    : 0;
System.debug('  Opps with line items:    ' + totalOppsWithItems);
System.debug('  Total line items:        ' + totalItems);
System.debug('  Avg items/opp:           ' + avgItemsPerOpp.setScale(2));
System.debug('  Max items on single opp: ' + maxItems);
System.debug('  Histogram:');
System.debug('    1 item:    ' + (histogram.containsKey(1)  ? histogram.get(1)  : 0) + ' opps');
System.debug('    2-3 items: ' + (histogram.containsKey(3)  ? histogram.get(3)  : 0) + ' opps');
System.debug('    4-5 items: ' + (histogram.containsKey(5)  ? histogram.get(5)  : 0) + ' opps');
System.debug('    6-10 items:' + (histogram.containsKey(10) ? histogram.get(10) : 0) + ' opps');
System.debug('    11-20 items:' + (histogram.containsKey(20) ? histogram.get(20) : 0) + ' opps');
System.debug('    20+ items: ' + (histogram.containsKey(99) ? histogram.get(99) : 0) + ' opps');
System.debug('================================================================');
