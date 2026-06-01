# Design: Intraday-Adjuster – Kostenreduktion (Ansatz B+C)

**Datum:** 2026-06-01  
**Status:** Approved  
**Problem:** Intraday-Adjuster verursacht ~€4+/Tag durch multi-turn Claude Sonnet Agent

---

## Entscheidung

| Workflow | Vorher | Nachher |
|---|---|---|
| Daily Optimizer | Claude Sonnet 4.6 (Agent) | Claude Sonnet 4.6 (Agent) – **unverändert** |
| Intraday Adjuster | Claude Sonnet 4.6 (Agent) | **Deterministisch (kein LLM)** |

Claude plant die Strategie einmal täglich (Preisschwellwert). Der Intraday-Adjuster vollzieht sie stündlich per Regeln – kein API-Call nötig.

**Kosten nach Umbau:**
- Daily Optimizer: ~€0.01–0.02/Tag (unverändert, vernachlässigbar)
- Intraday Adjuster: **€0.00/Tag**
- Gesamt: ~€0.01–0.02/Tag statt ~€4+/Tag

---

## Ziel-Architektur Intraday

### Vorher
```
n8n → InfluxDB → Claude Agent (multi-turn, MCP-Tools) → Entscheidung
```

### Nachher
```
n8n → evcc GET /api/state          ─┐
n8n → evcc GET /api/tariff/grid    ─┤ Code-Node (Regelwerk)
n8n → HA: Schwellwert lesen        ─┘
        ↓ charge_action + discharge_action
n8n → evcc: Limit setzen/entfernen (direkt)
n8n → evcc: Discharge steuern (unverändert)
```

---

## Regelwerk (Code-Node)

### Datenbeschaffung (neu)
- `GET http://192.168.1.8:7070/api/state` → SoC, chargePower pro Loadpoint, vehiclePresent
- `GET http://192.168.1.8:7070/api/tariff/grid` → aktueller Preis + nächste 2h
- `GET http://homeassistant:8123/api/states/sensor.battery_charge_threshold` → Tagesschwellwert von Claude (Daily Optimizer)
- HA: Einspeise-Schalter, Min-SoC (unverändert)

### charge_action

```
aktueller_preis = Tibber-Preis jetzt (ct/kWh)
schwellwert = sensor.battery_charge_threshold (ct/kWh)
naechster_guenstiger_slot = min(Preise nächste 2h) < schwellwert

wenn aktueller_preis <= schwellwert:
  → charge_action = "update", threshold_ct = schwellwert

sonst wenn aktueller_preis > schwellwert UND NICHT naechster_guenstiger_slot:
  → charge_action = "remove"

sonst:
  → charge_action = "keep"
```

### discharge_action

```
ev_laedt = any(loadpoint.chargePower > 0)
einspeise_aktiv = HA input_boolean.einspeise_logik_aktiv == "on"
soc = batterySoc
min_soc = HA input_number.min_soc_einspeisen
einspeiseverguetung = 6.7 ct/kWh

wenn ev_laedt:
  → discharge_action = "disable"  (Priorität: EV-Laden)

sonst wenn NICHT einspeise_aktiv:
  → discharge_action = "disable"

sonst wenn soc < min_soc:
  → discharge_action = "disable"

sonst wenn aktueller_preis > einspeiseverguetung:
  → discharge_action = "enable"

sonst:
  → discharge_action = "disable"
```

### reasoning (für HA-Sensor / Debugging)
Kurzer String der Entscheidungspfad: z.B. `"Preis 18.2ct > Schwellwert 15ct → keep; EV lädt → discharge disable"`

---

## Nodes entfernen

- `evcc MCP Tools` (mcpClientTool)
- `Claude Sonnet + evcc MCP` (Agent-Node)
- `Claude Sonnet 4.6` (LM-Sub-Node)
- `InfluxDB: Tibber Preisstats` (90d-Abfrage – nicht mehr nötig, Schwellwert kommt von Daily Optimizer)
- `InfluxDB: Verbrauch abfragen` (28d – nicht mehr nötig)
- `InfluxDB: Lastprofil abfragen` (nicht mehr nötig)
- `Kontext berechnen` (Code-Node – wird ersetzt)

## Nodes hinzufügen

- `evcc: State abrufen` (HTTP GET `/api/state`)
- `evcc: Tarif abrufen` (HTTP GET `/api/tariff/grid`)
- `HA: Schwellwert lesen` (HTTP GET `sensor.battery_charge_threshold`)
- `Entscheidung berechnen` (Code-Node mit Regelwerk oben)
- `evcc: Limit setzen` (HTTP POST `/api/batterygridchargelimit/{wert}`)
- `evcc: Limit entfernen` (HTTP DELETE `/api/batterygridchargelimit`)

## Nodes unverändert

- Trigger, KI-Schalter, Frequenz-Check
- HA: Einspeise-Schalter, Min-SoC lesen
- `Ergebnis extrahieren` (JSON-Parsing – Struktur bleibt gleich)
- Discharge-Steuerung via `/api/batterydischargecontrol/`
- HA-Status-Writes, Token-Tracking (zeigt 0 Tokens), InfluxDB-Writes

---

## Sensor-Persistenz (separates Problem)

Virtual sensors via `POST /api/states/` überleben keinen HA-Neustart.

**Fix:** HA-Automation auf Event `homeassistant_started` → triggert n8n Daily Optimizer Webhook. Sensoren werden danach sofort neu geschrieben.

---

## Offene Punkte zur Verifikation beim ersten Run

- Exakter evcc REST-Endpunkt für Battery Grid Charge Limit (POST-Format: Pfadparameter vs. Body). Fallback: weiterhin MCP via JSON-RPC aus n8n heraus.
- Struktur von `/api/state` Response (Feldnamen für SoC, loadpoints, solarForecast).
- Struktur von `/api/tariff/grid` Response (Feldname für aktuellen Preis).
