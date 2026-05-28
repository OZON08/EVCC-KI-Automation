# Phase 5 – Einspeise-Logik Design Spec
_Datum: 2026-05-28_

## Ziel

Batterie ins Netz entladen wenn prognostizierter Energieüberschuss vorliegt (Solar + SoC deckt Restbedarf) und der Tibber-Preis die Einspeisevergütung übertrifft. Die Entscheidung wird in den bestehenden Intraday Adjuster integriert – kein separater Workflow.

## Bedingungen für Entladung

```
Entladen erlaubt wenn:
  einspeise_logik_aktiv = on
  UND SoC > min_soc_einspeisen (konfigurierbar, default 30%)
  UND Solar + SoC-Energie > verbleibender Tagesbedarf (Überschuss)
  UND aktueller Tibber-Preis > 6,7 ct (Einspeisevergütung) + Puffer
```

## Änderungen an `intraday-adjuster.json`

### Neue Nodes (sequentiell nach "KI aktiv?")

1. **`HA: Einspeise-Schalter lesen`** — `GET /api/states/input_boolean.einspeise_logik_aktiv`
2. **`HA: Min-SoC lesen`** — `GET /api/states/input_number.min_soc_einspeisen`

Beide Werte werden in "Kontext berechnen" via `$('Node Name').first()` abgerufen und in den Prompt eingebaut.

### Erweiterter Claude-Prompt (Kontext berechnen)

Zusätzliche Zeilen im Prompt:
```
Einspeise-Logik aktiv: ja/nein
Minimaler SoC für Einspeisen: X%
Einspeisevergütung: 6,7 ct/kWh (fix)

Zusätzliche Entscheidung (discharge_action):
- Wenn Einspeise-Logik aus: discharge_action = "disable"
- Wenn an UND SoC > min_soc UND Überschuss vorhanden UND Tibber-Preis > 6,7 ct + Puffer:
    discharge_action = "enable"
- Sonst: discharge_action = "disable"
```

### Neues JSON-Format von Claude

```json
{
  "charge_action": "keep|update|remove",
  "threshold_ct": 0,
  "discharge_action": "enable|disable",
  "reasoning": "kurze deutsche Begründung"
}
```

### Ergebnis extrahieren (Code-Node Update)

Regex angepasst auf `"charge_action"` (statt `"action"`), zusätzlich `discharge_action` parsen.

### Neuer Node: `evcc: Entladung setzen`

```
POST http://192.168.1.8:7070/api/batterydischargecontrol/true   (wenn enable)
POST http://192.168.1.8:7070/api/batterydischargecontrol/false  (wenn disable)
```

IF-Node nach Extraktion: `discharge_action == "enable"` → true/false Branch.

### HA-Sensor Update

`sensor.battery_intraday_adjustment` bekommt `discharge_action` als zusätzliches Attribut.

## Neue HA Entities

| Entity | Typ | Werte | Default |
|--------|-----|-------|---------|
| `input_number.min_soc_einspeisen` | Schieberegler | 10–50%, Schritt 5% | 30% |

In `ha-config/input_numbers.yaml` ergänzen.

## Dashboard-Erweiterung

Steuerungskarte erhält neuen Slider:
```yaml
- entity: input_number.min_soc_einspeisen
  name: "Min. SoC Einspeisen"
```

`sensor.battery_intraday_adjustment` Karte zeigt zusätzlich `discharge_action` Attribut.

## Interaktion mit bestehenden Komponenten

| Komponente | Verhalten |
|------------|-----------|
| Safety Monitor | Bleibt unverändert – schützt bei SoC < 10% |
| HA Override Handler | `discharge_enabled/disabled` Events überschreiben Intraday-Entscheidung sofort |
| Daily Optimizer | Unverändert – kümmert sich nur um Laden |

## Dateien die geändert werden

- `n8n-workflows/intraday-adjuster.json` — Hauptänderung
- `ha-config/input_numbers.yaml` — min_soc_einspeisen hinzufügen
- `ha-config/dashboards/battery-ai-dashboard.yaml` — Slider + discharge_action Attribut
- `README.md` — Phase 5 Status auf "Live" setzen
