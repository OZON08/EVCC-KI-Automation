# Design Spec: KI-Batteriesteuerung
_Erstellt: 2026-05-25_

## Kontext & Ziel

Hausbatterie RCT Power (7,6 kWh, ~7 kW) wird durch evcc gesteuert. Tibber liefert dynamische Preise im 15-Minuten-Raster. Ziel: Batterie kostenoptimiert aus dem Netz laden – nur wenn Tibber-Preis günstig **und** Solar-Prognose niedrig. Claude Sonnet entscheidet täglich den optimalen Preisschwellwert. Einspeisevergütung 6,7 ct/kWh fix (Einspeisung kaum rentabel). Einspeisebetrieb per Schalter optional.

## Architektur

```
n8n (Orchestrator)
  └─ Daily Optimizer (14:00)
       ├─ evcc /api/state       → SoC, Preise, Solar-Prognose
       ├─ InfluxDB Query        → Verbrauchshistorie (28d)
       ├─ HA API                → Schalter-Status prüfen
       ├─ Claude Sonnet         → Preisschwellwert-Entscheidung
       ├─ evcc /batterygridchargelimit → Schwellwert setzen
       └─ HA API                → Status zurückschreiben

  └─ Safety Monitor (alle 15 min, regelbasiert)
       └─ SoC-Grenzen: >95% → Netzladen aus, <10% → Entladen aus

  └─ HA Override Webhook Handler (regelbasiert)
       └─ Schalter-Events → sofortige API-Calls an evcc

Home Assistant
  ├─ input_boolean.ki_batteriesteuerung_aktiv
  ├─ input_boolean.einspeise_logik_aktiv
  ├─ input_number.manueller_preisschwellwert (0 = KI übernimmt)
  └─ Dashboard: SoC, Schwellwert, nächstes Fenster, Kosten
```

## Aufgabenteilung

| Komponente | Aufgabe |
|------------|---------|
| Claude Sonnet | Entscheidung: optimaler Schwellwert + Begründung |
| n8n | Datensammlung, Ausführung, Safety, HA-Kommunikation |
| evcc | Batteriesteuerung (lädt selbst wenn Preis < Schwellwert) |
| evcc MCP | Optional: Read-Tool für Claude (experimentell) |

## Claude Sonnet Prompt-Design

**System Prompt:**
```
Du bist ein Energieoptimierungs-Agent für eine Hausbatterie.
Specs: 7,6 kWh Kapazität, max. 7 kW Ladeleistung.
Einspeisevergütung: 6,7 ct/kWh (fix, Entladen ins Netz lohnt kaum).
Ziel: Finde den optimalen Preisschwellwert (ct/kWh) für evcc's
batterygridchargelimit. Unterhalb dieses Wertes lädt evcc die Batterie
automatisch aus dem Netz.
Gib IMMER eine JSON-Antwort zurück:
{ "threshold_ct": <Zahl>, "reasoning": "<kurze Begründung DE>" }
```

**User-Nachricht (dynamisch von n8n befüllt):**
```
Aktueller SoC: {soc}%
Tibber-Preise morgen (ct/kWh, 15-min-Slots): {preisliste}
Solar-Prognose morgen: {solar_kwh} kWh
Durchschnittlicher Tagesverbrauch (gleicher Wochentag): {verbrauch_kwh} kWh
Einspeise-Logik aktiv: {ja|nein}
```

## Optimierungslogik (Claude-Guidance)

Claude soll folgende Faktoren gewichten:

1. **Energiebedarf**: `bedarf = verbrauch - solar - verfügbare_kapazität`
   - Wenn `bedarf ≤ 0`: Schwellwert = 0 (kein Netzladen nötig)
2. **Preiswahl**: Günstigste Stunden identifizieren, die Bedarf decken
3. **Schwellwert**: Obere Grenze der gewählten günstigen Stunden + kleiner Puffer
4. **Einspeise-Logik**: Wenn aktiv, Entladen bei hohen Preisen in Betracht ziehen (Tibber > 6,7 ct deutlich)

## evcc REST API (relevante Endpoints)

| Endpoint | Zweck |
|----------|-------|
| `GET /api/state` | Gesamtstatus (SoC, Preise, Prognosen) |
| `POST /api/batterygridchargelimit/{cent}` | Preisschwellwert setzen |
| `DELETE /api/batterygridchargelimit` | Netzladen deaktivieren |
| `POST /api/batterydischargecontrol/{bool}` | Entladesteuerung |
| `POST /auth/login` | Auth-Cookie holen |

## Fehlerbehandlung

| Fehler | Verhalten |
|--------|-----------|
| InfluxDB offline | Fallback 10 kWh/Tag, Claude bekommt Hinweis |
| Tibber-Preise fehlen | Workflow abbrechen, Schwellwert unverändert |
| evcc offline | Retry 3×/30s, dann HA-Notification |
| Claude Response unparsebar | Letzter Schwellwert bleibt, HA-Notification |
| SoC > 95% | Safety Monitor: Netzladen sofort aus |
| SoC < 10% | Safety Monitor: Entladen sofort aus |

## InfluxDB Query

```sql
SELECT mean("value") FROM "gridPower"
WHERE time > now() - 28d
  AND weekday(time) = $wochentag
GROUP BY time(1h)
```
_Messfeld-Name `gridPower` muss gegen tatsächliches evcc-Schema verifiziert werden._

## Implementierungsphasen

1. **Phase 1**: Grundgerüst – Daily Optimizer mit statischem Fallback, Safety Monitor, HA-Basis
2. **Phase 2**: InfluxDB-Lernkomponente – echte Verbrauchsdaten für Claude
3. **Phase 3**: Override & Monitoring – HA Webhooks, Status-Sensoren, Dashboard-Grafiken
4. **Phase 4** (optional): Einspeise-Logik vollständig ausbauen
