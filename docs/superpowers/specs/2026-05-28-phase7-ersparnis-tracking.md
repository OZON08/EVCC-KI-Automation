# Phase 7 – Ersparnis-Tracking Design Spec
_Datum: 2026-05-28_

## Ziel

Täglich um 23:55 berechnet ein neuer n8n-Workflow die KI-gesteuerte Ersparnis: tatsächliche Ladekosten vs. was es beim Tagesdurchschnittspreis gekostet hätte. Stündlich, täglich und monatlich im Dashboard sichtbar.

## Ersparnis-Formel

```
Tagesdurchschnitt = mean(tariffGrid) für heute (ct/kWh)
Tatsächliche Kosten = Σ (Energie geladen in Slot × Tibber-Preis in dem Slot)
Referenzkosten = gleiche Energie × Tagesdurchschnitt
Ersparnis heute = Referenzkosten − Tatsächliche Kosten (EUR)
```

## Datenquellen (InfluxDB)

| Messung | Verwendung |
|---------|-----------|
| `batteryPower` | Ladeleistung in W (positiv = laden). Integral → kWh geladen pro Slot |
| `tariffGrid` | Tibber-Preis ct/kWh pro Slot (× 0.01 = EUR/kWh) |

**Hinweis:** Die Korrelation von `batteryPower` und `tariffGrid` erfolgt über GROUP BY time(1h). Falls evcc eine dedizierte `batteryGridEnergy`-Messung schreibt, diese bevorzugen.

## InfluxDB-Queries

```sql
-- Stündliche Lademengen heute
SELECT integral("value") / 3600000 as kwh
FROM "batteryPower"
WHERE value > 0 AND time >= '<heute-00:00Z>'
GROUP BY time(1h) fill(0)

-- Stündliche Tibber-Preise heute
SELECT mean("value") * 100 as price_ct
FROM "tariffGrid"
WHERE time >= '<heute-00:00Z>'
GROUP BY time(1h) fill(none)

-- Tagesdurchschnitt
SELECT mean("value") * 100 as avg_ct
FROM "tariffGrid"
WHERE time >= '<heute-00:00Z>'
```

## Neuer Workflow: `savings-tracker.json`

**Trigger:** `55 23 * * *` (täglich 23:55)

**Flow:**
```
Trigger (23:55)
  → HA: KI-Schalter prüfen (abort wenn off)
  → InfluxDB: batteryPower heute stündlich
  → InfluxDB: tariffGrid heute stündlich + Tagesdurchschnitt
  → Ersparnis berechnen (Code-Node)
  → HA: sensor.battery_ai_savings_today
  → InfluxDB: Ersparnis als Zeitreihe speichern (für Monatssumme)
  → InfluxDB: SELECT sum(savings_eur) dieser Monat
  → HA: sensor.battery_ai_savings_month
```

## Code-Node: Ersparnis berechnen

```javascript
// Stündliche Daten zusammenführen (JOIN über Timestamp)
// Für jeden Slot: kwh × (avg_ct - slot_ct) / 100
// Negative Werte auf 0 kappen (wenn Slot teurer als Durchschnitt war: kein "Verlust")
const savings_today = slots.reduce((sum, slot) => {
  const saved = slot.kwh * (avg_ct - slot.price_ct) / 100;
  return sum + Math.max(0, saved);
}, 0);
```

**Runden auf 4 Dezimalstellen** (EUR).

## InfluxDB Write (Tageswert für Monatssumme)

```
POST /write?db=evcc
battery_savings,period=daily savings_eur=0.1234
```

## Neue HA Entities

| Entity | Inhalt | Einheit |
|--------|--------|---------|
| `sensor.battery_ai_savings_today` | Ersparnis heute (Tagesabschluss) | EUR |
| `sensor.battery_ai_savings_month` | Ersparnis kumuliert dieser Monat | EUR |

**Stündliche Anzeige:** Intraday Adjuster kann optional `sensor.battery_ai_savings_running` schreiben (laufende Tagessumme bis zur aktuellen Stunde) – separates Feature, nicht in dieser Phase.

## Dashboard-Erweiterung

```
KI-Ersparnis
  Heute:        X.XX €
  Dieser Monat: X.XX €
  [History Graph: savings_eur letzte 30 Tage]
```

## Dateien die erstellt/geändert werden

- `n8n-workflows/savings-tracker.json` (neu)
- `ha-config/dashboards/battery-ai-dashboard.yaml` — Ersparnis-Karte
- `README.md` — Phase 7 auf "Live" setzen nach Aktivierung

## Verifikation

1. Manuell triggern → `sensor.battery_ai_savings_today` in HA prüfen
2. Wert gegen manuelle Rechnung validieren: evcc UI zeigt Ladeenergie + Tibber-Preise
3. Monatssumme nach 2 Tagen prüfen ob kumuliert wird
4. Edge case: kein Netzladen heute → savings_today = 0 (nicht negativ)
