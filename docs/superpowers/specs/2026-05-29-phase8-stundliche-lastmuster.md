# Phase 8 – Stündliche Lastmustererkennung Design Spec
_Datum: 2026-05-29_

## Ziel

Wiederkehrende stündliche Verbrauchsspitzen (z.B. Wärmepumpe 7–9 Uhr) erkennen und Claude als Kontext übergeben. Claude berechnet daraus den Netto-Bedarf pro Stunde (Lastprofil minus PV-Prognose) und plant die Ladestrategie so, dass die Batterie rechtzeitig genug SoC-Reserve hat.

## Kernlogik

```
Netto-Bedarf (Stunde h) = Lastprofil[h] − PV-Prognose[h]

Wenn Netto-Bedarf[h] > 0:
  → Batterie muss zu diesem Zeitpunkt genug SoC haben
  → Claude plant Ladestrategie rückwärts: wann muss geladen werden?

Wenn PV Lastspitze abdeckt (Netto-Bedarf ≤ 0):
  → Keine extra Reserve nötig für diese Stunde
```

## InfluxDB-Query (neu)

```sql
SELECT integral("value") / 3600000 as kwh
FROM "homePower"
WHERE time > now() - 28d
GROUP BY time(1h) fill(0)
```

Liefert alle Stundenwerte der letzten 28 Tage. Filterung auf gleichen Wochentag und Aggregation nach Stunde des Tages erfolgt im Code-Node.

## Neuer Code-Node: "Lastprofil berechnen"

Positionierung: nach InfluxDB-Queries, vor Prompt-Aufbau.

```javascript
const series = $input.first()?.json?.results?.[0]?.series?.[0]?.values ?? [];
const todayWeekday = new Date().getDay();

// Stundenwerte nach Stunde des Tages gruppieren (gleicher Wochentag)
const byHour = {};
for (let h = 0; h < 24; h++) byHour[h] = [];

// Dynamischer Timezone-Offset (funktioniert für CET/CEST automatisch)
const offsetHours = -new Date().getTimezoneOffset() / 60;

series
  .filter(([time]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    return local.getDay() === todayWeekday;
  })
  .forEach(([time, kwh]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    const hour = local.getHours();
    if (kwh > 0) byHour[hour].push(kwh);
  });

// Durchschnitt pro Stunde
const profile = Object.entries(byHour).map(([hour, vals]) => ({
  hour: parseInt(hour),
  avg_kwh: vals.length > 0
    ? Math.round(vals.reduce((a, b) => a + b, 0) / vals.length * 100) / 100
    : 0,
  samples: vals.length
}));
```

Fallback: wenn weniger als 4 Messtage vorhanden → Stundenprofil weglassen, nur Tagesdurchschnitt verwenden.

## Prompt-Erweiterung

Beide Workflows (Daily Optimizer + Intraday Adjuster) bekommen zusätzlichen Abschnitt:

```
Stündliches Verbrauchsprofil (gleicher Wochentag, 28d Durchschnitt):
  00:00: 0.2 kWh | 01:00: 0.2 kWh | ... | 07:00: 1.8 kWh | 08:00: 2.1 kWh | ...

PV-Prognose stündlich: via getState abrufen (forecast.solar.hourly falls verfügbar,
sonst Tagesprognose gleichmäßig auf Tagesstunden 6–20 Uhr verteilen).

Berechne pro Stunde: Netto-Bedarf = Verbrauch − PV-Prognose.
Stunden mit Netto-Bedarf > 0 brauchen Batterie-Reserve.
Plane die Ladestrategie so dass SoC rechtzeitig ausreicht:
  rückwärts planen: wenn um 8 Uhr 1.5 kWh Netto-Bedarf → um 7 Uhr mind. X% SoC nötig.
```

## Änderungen an bestehenden Workflows

### `daily-optimizer.json`

1. **Neuer Node** "InfluxDB: Lastprofil abfragen" (sequentiell nach bestehendem Verbrauch-Node – n8n parallele Inputs crashen Code-Nodes)
2. **Erweiterung "Verbrauch berechnen"** Code-Node: Lastprofil-Berechnung integrieren, kompaktes Profil-String für Prompt bauen
3. **Prompt-Erweiterung** in "Verbrauch berechnen": Lastprofil-Abschnitt anhängen

### `intraday-adjuster.json`

1. **Neuer Node** "InfluxDB: Lastprofil abfragen" (sequentiell nach bestehenden InfluxDB-Nodes)
2. **Erweiterung "Kontext berechnen"** Code-Node: Lastprofil aus Node via `$('InfluxDB: Lastprofil abfragen').first()` lesen, für die **nächsten 6 Stunden** filtern (nur relevanter Ausschnitt um Prompt-Länge zu begrenzen)
3. **Prompt-Erweiterung** in "Kontext berechnen"

## PV-Prognose stündlich

evcc MCP `getState` liefert `forecast.solar`. Die Struktur muss beim Implementieren geprüft werden:

```
Prüfen ob vorhanden:
  forecast.solar.tomorrow.slots[]  → stündliche Werte (bevorzugt)
  forecast.solar.today.slots[]     → stündliche Werte heute

Falls slots vorhanden:
  → direkt als stündliche PV-Prognose verwenden

Falls nur Tageswert (forecast.solar.tomorrow.energy in Wh):
  → Fallback: Energie gleichmäßig auf 6–20 Uhr verteilen (÷ 14 Stunden)
  → Claude-Prompt-Hinweis: "Stündliche PV-Prognose nicht verfügbar,
     Schätzung: X kWh gleichmäßig auf 6–20 Uhr verteilt"
```

**Implementierungshinweis:** Claude im Prompt anweisen die Struktur von `forecast.solar` zu prüfen und `slots` zu bevorzugen. Bekannt aus bisherigem Code: `forecast.solar.tomorrow.energy` existiert (Wh → ÷1000 = kWh). Ob `slots` verfügbar ist muss mit echtem MCP-Aufruf verifiziert werden.

## Wichtige Einschränkung: Intraday vs. Daily

| Workflow | Lastprofil-Horizont |
|----------|-------------------|
| Daily Optimizer (14:00) | Vollständiges 24h-Profil für morgen |
| Intraday Adjuster (stündlich) | Nur nächste 6 Stunden (Prompt-Effizienz) |

## Dateien die geändert werden

- `n8n-workflows/daily-optimizer.json`
- `n8n-workflows/intraday-adjuster.json`
- `README.md` — Phase 8 ergänzen

## Verifikation

1. InfluxDB-Query manuell testen: liefert stündliche Werte für letzten Monat?
2. Daily Optimizer manuell triggern → Claude-Reasoning enthält Lastprofil-Erwähnung
3. Morgens zwischen 7–9 Uhr Intraday triggern → Claude erwähnt bevorstehende Spitze
4. Sonniger Tag: Claude ignoriert Lastspitze wenn PV sie abdeckt
