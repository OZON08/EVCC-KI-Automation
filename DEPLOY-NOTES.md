# CLAUDE.md – Projektkontext für Claude Code

Dieses Dokument beschreibt das Projekt und offene Aufgaben für die lokale Claude Code-Instanz.

## Projekt

KI-gesteuerte Batterie-Automatisierung für eine Heimanlage mit:
- **Batterie**: 7,6 kWh (Kapazität wird dynamisch aus EVCC gelesen)
- **PV-Hauptanlage**: 9,5 kWp (EVCC-Quellen: „Dach vorne" + „Dach hinten")
- **Balkonkraftwerk**: 0,8 kW (EVCC-Quelle: „Garage")
- **Wallbox**: 2 E-Fahrzeuge
- **Stromtarif**: Tibber (dynamisch)
- **Einspeisevergütung**: 6,7 ct/kWh (jetzt konfigurierbar via HA)

## Offene Aufgabe: Branch mergen und deployen

Der Branch `claude/battery-discharge-issue-sJida` enthält fertige Fixes und Features.
Er muss in `main` gemergt und dann in Home Assistant + n8n eingespielt werden.

### Schritt 1: Branch in main mergen

```bash
git checkout main
git pull origin main
git merge claude/battery-discharge-issue-sJida
git push origin main
```

### Schritt 2: HA-Config einspielen

Die Datei `ha-config/input_numbers.yaml` wurde erweitert. Neu hinzugekommen:

```yaml
input_number:
  einspeise_verguetung_ct:
    name: "Einspeisevergütung"
    icon: mdi:transmission-tower-export
    unit_of_measurement: "ct/kWh"
    min: 0
    max: 30
    step: 0.1
    initial: 6.7
    mode: box
```

**Vorgehen**: In Home Assistant unter *Einstellungen → Helfer* den neuen Input Number
`input_number.einspeise_verguetung_ct` anlegen, oder die YAML-Konfiguration in die
`configuration.yaml` bzw. das entsprechende `input_number`-Package einspielen und HA neustarten.

Den Wert auf die tatsächliche Einspeisevergütung setzen (Standard: 6,7 ct/kWh).

### Schritt 3: n8n Workflows importieren

Beide geänderten Workflows in n8n importieren (Workflow → Import from file):

| Datei | Änderungen |
|---|---|
| `n8n-workflows/intraday-adjuster.json` | Neuer Node „HA: Einspeise-Verguetung lesen", Entladungs-Bugfixes |
| `n8n-workflows/daily-optimizer.json` | Solar-Forecast für 3 Quellen, PV-Specs im Systemprompt, Batteriekapazität dynamisch |

Nach dem Import: Workflows aktivieren und einmal manuell triggern zum Testen.

### Schritt 4: Prüfen ob alles läuft

In Home Assistant prüfen:
- `sensor.battery_intraday_adjustment` → Attribut `reasoning` zeigt den aktuellen Entscheidungsgrund
- `sensor.battery_charge_threshold` → Wert > 0 wenn Netzladen heute sinnvoll ist
- Bei Tibber-Preis > 6,7 ct und SoC > Min-SoC: `discharge_action` muss `enable` sein

---

## Was wurde in dieser Session gefixt

### Bug 1: Batterie entlädt sich nicht obwohl Preis hoch (z.B. 30 ct)

**Ursache**: Wenn `sensor.battery_charge_threshold` noch nicht existiert (Daily Optimizer
noch nicht gelaufen), brach der Intraday Adjuster sofort mit `discharge_action: disable` ab —
unabhängig vom Tibber-Preis.

**Fix**: Entladungs-Logik läuft jetzt immer durch. Fehlendes Schwellenwert-Sensor
betrifft nur die Lade-Entscheidung (`charge_action: keep`), nicht die Entladung.

### Bug 2: Unbekannter Tibber-Preis sperrt Entladung

**Ursache**: Wenn die Tibber-API keinen Slot für den aktuellen Zeitpunkt lieferte,
war `currentPriceCt = null` → Entladung blieb stumm deaktiviert.

**Fix**: Bei `currentPriceCt === null` wird die Entladung jetzt erlaubt
(Reasoning: „Preis unbekannt – Entladung erlaubt").

### Bug 3: Solar-Forecast las 0 kWh bei mehreren PV-Quellen

**Ursache**: Code las `forecast.solar.tomorrow` — bei benannten EVCC-Quellen
(„Dach vorne", „Dach hinten", „Garage") gibt es diesen Key nicht. Ergebnis: 0 kWh.
Der Optimizer plante deshalb täglich unnötig viel Netzladen ein.

**Fix**: Neuer Code erkennt alle drei EVCC-Formate und summiert alle Quellen.

### Feature: PV-Anlage in Claude-Systemprompt

Claude kennt jetzt die konkrete Anlage (9,5 kWp + 0,8 kW BKW) und kann
bessere Entscheidungen für sonnige Tage treffen.

### Feature: Einspeisevergütung konfigurierbar

Neuer HA-Slider `input_number.einspeise_verguetung_ct` — kein Code-Edit mehr
nötig wenn sich der Tarif ändert.

### Feature: Batteriekapazität dynamisch

Wird jetzt aus `evccState.batteryCapacity` gelesen statt hardcodiert auf 7,6 kWh.
