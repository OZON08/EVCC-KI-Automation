# Design: Intraday-Adjuster – Kostenreduktion (Ansatz B)

**Datum:** 2026-06-01  
**Status:** Approved  
**Problem:** Intraday-Adjuster verursacht ~€4+/Tag durch multi-turn Claude Sonnet Agent

---

## Kontext

Der Intraday-Adjuster läuft stündlich 6–22 Uhr (17x/Tag). Aktuell ist Claude als **Agent** konfiguriert: er ruft selbst `getState` und `getTariffInfo` via MCP auf, der Kontext wächst über 3–4 Turns auf ~15.000 Input-Tokens pro Lauf. Mit Claude Sonnet 4.6 ($3/1M input, $15/1M output) entstehen so ~€4+/Tag.

Der Daily Optimizer (1x/Tag) bleibt vorerst unverändert.

---

## Ziel-Architektur

Claude wird vom **Executor** zum **Entscheider**. n8n holt alle Daten, Claude bekommt einen fertigen Kontext und gibt JSON zurück. Kein Agent-Loop, keine Tool-Calls.

### Vorher (multi-turn Agent)
```
n8n → Claude Agent
         ↓ tool: getState (MCP)
         ↓ tool: getTariffInfo (MCP)
         ↓ tool: setBatteryGridChargeLimit (MCP)
       ~15.000 Input-Tokens, Sonnet 4.6
```

### Nachher (single-turn Chat)
```
n8n → GET /api/state          ─┐
n8n → GET /api/tariff/grid    ─┤ Code-Node (verdichten)
n8n → InfluxDB (unverändert)  ─┘
        ↓
      Claude Haiku 4.5 (1 Turn, kein Agent)
        ↓ JSON-Entscheidung
n8n → POST/DELETE /api/batterygridchargelimit (direkt)
n8n → batterydischargecontrol (unverändert)
```

**Geschätzte Kosten nach Umbau:** ~$0.002/Run × 17 = ~$0.034/Tag ≈ €0.03/Tag

---

## Änderungen am Workflow

### Nodes entfernen
- `evcc MCP Tools` (mcpClientTool)
- `Claude Sonnet + evcc MCP` (Agent-Node)
- `Claude Sonnet 4.6` (LM-Sub-Node des Agents)

### Nodes hinzufügen

**1. `evcc: State abrufen`** – HTTP GET
```
GET http://192.168.1.8:7070/api/state
```
Keine Auth nötig (lokales Netz).

**2. `evcc: Tarif abrufen`** – HTTP GET
```
GET http://192.168.1.8:7070/api/tariff/grid
```

**3. `Kontext verdichten`** – Code-Node (ersetzt/erweitert bestehenden `Kontext berechnen`)

Extrahiert aus dem evcc-State:
- `batterySoc`, `batteryPower`
- `solarForecast` (heute Rest + morgen)
- Pro Loadpoint: `vehiclePresent`, `chargePower`, `planTime`, `planEnergy`

Extrahiert aus Tarif:
- Nur nächste 12h Preise (nicht 48h)

Baut kompakten Prompt (deklarativ, keine Prozedur-Schritte):
```
Batterie: SoC 72%, 2.2 kWh frei
Solar-Prognose: heute noch 1.4 kWh | morgen 12.8 kWh
Loadpoint 1: kein Fahrzeug
Loadpoint 2: lädt, 8 kWh ausstehend, Plan bis 07:00
Tibber nächste 12h: 14:00=18.2ct 15:00=17.1ct ... 22:00=24.1ct
Hist. Preise (90d): Ø19.8ct | Min 9.1ct | Max 38.2ct
Tagesverbrauch: 12.4 kWh | Restbedarf: ~5.1 kWh
Einspeise-Logik: an | Min-SoC: 30%

Entscheide und antworte NUR mit JSON:
{"charge_action":"keep"|"update"|"remove","threshold_ct":0,"discharge_action":"enable"|"disable","reasoning":"<kurz>"}
```

**4. `Claude Haiku` (Chat-Node, kein Agent)**
- Model: `claude-haiku-4-5-20251001`
- Temperature: 0
- System: `Du bist ein Batterie-Entscheidungs-Agent. Antworte NUR mit validem JSON, kein Text davor oder danach.`
- Input: User-Message = fertiger Kontext-String

**5. `evcc: Limit setzen`** – HTTP POST (bei charge_action=update)
```
POST http://192.168.1.8:7070/api/batterygridchargelimit/{value_eur}
```
Hinweis: Exaktes API-Format beim ersten Run gegen evcc verifizieren (Pfad-Parameter vs. Body). Fallback: MCP direkt per JSON-RPC ansprechen.

**6. `evcc: Limit entfernen`** – HTTP DELETE (bei charge_action=remove)
```
DELETE http://192.168.1.8:7070/api/batterygridchargelimit
```

### Nodes unverändert
- Trigger, KI-Schalter, Frequenz-Check
- HA: Einspeise-Schalter, Min-SoC
- InfluxDB: Tibber-Stats, Verbrauch, Lastprofil
- `Ergebnis extrahieren` (JSON-Parsing bleibt gleich)
- Discharge-Steuerung via `/api/batterydischargecontrol/`
- HA-Status-Writes, Token-Tracking, InfluxDB-Writes

---

## Sensor-Persistenz (separates Problem)

Virtual sensors via `POST /api/states/` überleben keinen HA-Neustart.

**Fix:** HA-Automation `homeassistant_started` → ruft n8n-Webhook auf, der beide Workflows einmal triggert. Sensoren werden danach sofort neu geschrieben.

Alternativ: `input_number`/`input_text` Helfer in HA definieren – aufwändiger, aber persistiert.

**Empfehlung:** Webhook-Trigger-Automation als schnellste Lösung.

---

## Kostenschätzung

| | Vorher | Nachher |
|---|---|---|
| Model | Sonnet 4.6 | Haiku 4.5 |
| Input-Tokens/Run | ~15.000 | ~2.500 |
| Output-Tokens/Run | ~500 | ~150 |
| Kosten/Run | ~$0.05 | ~$0.002 |
| Läufe/Tag | 17 | 17 |
| **Kosten/Tag** | **~€0.85+** | **~€0.03** |

Reale Kosten waren höher (~€4/Tag), vermutlich durch MCP-Responses die größer als erwartet sind. Der single-turn Ansatz ist unabhängig davon deterministisch günstiger.

---

## Nicht im Scope

- Daily Optimizer bleibt unverändert (1x/Tag, vernachlässigbare Kosten)
- Kein Umbau auf deterministische Logik (Ansatz C) – bleibt Fallback
- Keine Änderung an savings-tracker, ha-override-handler, safety-monitor
