# Backend To-Do til Grok

Forslag til en ny kontrakt. iOS-klienten kalder kun den nuværende v1-kontrakt, indtil vi har aftalt og testet udvidelserne. Bevar token i Bearer-headeren og adgangen via den valgte PC-profil. Nye ID’er skal være stabile, uigennemsigtige strenge. Eksponér hverken filstier, tokens eller interne serverfejl.

| Funktion | Foreslået request | Foreslået response |
| --- | --- | --- |
| Modeloversigt | GET /api/v2/models | 200 `{"default_model_id":"m1","models":[{"id":"m1","label":"Model A","available":true,"capabilities":["chat"]}]}` |
| Modelvalg og kildekontekst | POST /api/v2/chat med `{"message":"…","session_id":"…","model_id":"m1","request_id":"UUID","context":[{"source_id":"note-1","title":"Note","excerpt":"…"}],"parent_message_id":null}` | 200 SSE. Se eventtabellen nedenfor. `context` og `parent_message_id` er valgfrie. Medtag kun lokalt indhold efter brugerens valg. |
| Sammenligning | Brug to uafhængige POST /api/v2/chat med samme tekst, forskellige `model_id`, `session_id` og `request_id`. Ingen særskilt route. | To SSE-strømme, hver med sit eget svar, status og statistik. Serveren må gerne afvikle dem sekventielt for at holde sig inden for PC’ens kapacitet. |
| MCP-værktøjer | GET /api/v2/mcp/tools | 200 `{"tools":[{"server_id":"s1","name":"lookup","description":"…","input_schema":{"type":"object"},"requires_confirmation":true}]}` |
| MCP-kald | POST /api/v2/mcp/tools/call med `{"server_id":"s1","name":"lookup","arguments":{},"request_id":"UUID"}` | 200 `{"content":[{"type":"text","text":"…"}],"structured_content":null,"is_error":false}`. PC’en styrer tilladte servere, værktøjer og bekræftelseskrav. Aftal MCP Streamable HTTP og JSON-RPC separat, hvis telefonen skal være en direkte MCP-klient. |
| Ryd jobhistorik på PC | DELETE /api/v2/jobs?scope=terminal efter bekræftelse | 200 `{"removed_job_ids":["job-id"],"active_jobs_untouched":true}`. Behold videofiler og aktive jobs. |

For nye HTTP-fejl foreslås samme envelope som v1 med `{"error":{"code":"…","message":"…"}}`. Aftal 401 for token, 404 for ukendte ID’er, 409 for en konflikt med et tidligere request-id, 422 for ugyldigt input og 503 for midlertidigt utilgængelige modeller eller værktøjer. Et gentaget request-id må aldrig starte endnu et værktøj eller job.

| SSE-type i v2 | Eksempel på eventdata |
| --- | --- |
| text | `{"type":"text","content":"…"}` |
| tool_status | `{"type":"tool_status","content":"Søger…"}` |
| step | `{"type":"step","step_id":"s1","parent_step_ids":[],"title":"Søgning","state":"running"}` |
| citation | `{"type":"citation","source_id":"note-1","title":"Note","url":null,"excerpt":"…"}` |
| done | `{"type":"done","content":"","message_id":"msg-1","model_id":"m1","usage":{"input_tokens":100,"output_tokens":42,"elapsed_ms":850}}` |

Definér `step.state` som `queued`, `running`, `completed` eller `failed`. Gentag et step-id ved opdatering. Et svar uden `done` behandles som afbrudt. Sammenligning og branch må ikke genbruge den oprindelige samtales ID ved nye, uafhængige sessioner.

iCloud-synkronisering kræver Apple-signering, en aftalt CloudKit-container og synkroniseringstest på to enheder. Det kræver ingen ændring i PC-API’et. Siri-genveje åbner chat eller klipvalg lokalt. Et senere bekræftet job kan bruge det eksisterende job-POST.

## Agent-Hub

Foreslået, endnu uden klientkald. Brug samme Bearer-token og fejlenvelope som v1.

| Request | Svar |
| --- | --- |
| `GET /api/v2/agent-hub` | 200 `{"revision":12,"rooms":[{"id":"research","name":"Research Lab","icon":"search"}],"agents":[{"id":"researcher","room_id":"research","name":"Researcher","icon":"search","status":"thinking","xp":35,"level":1,"xp_in_level":35,"xp_for_next_level":100,"recent_quests":[{"id":"q1","title":"Søgning","state":"running","updated_at":"2026-11-06T12:00:00Z"}]}],"summary":{"active_agents":1,"active_jobs":2,"total_xp":35,"streak_days":3}}` |
| `GET /api/v2/agents/{agent_id}/history?limit=50&cursor=…` | 200 `{"items":[{"id":"e1","kind":"tool_call","title":"Søgning","state":"completed","at":"2026-11-06T12:00:00Z","tool_name":"search","summary":"Fandt 2 resultater"}],"next_cursor":null}` |
| `GET /api/v2/agents/{agent_id}/memory?limit=50&cursor=…` | 200 `{"items":[{"id":"m1","title":"Søgepræferencer","summary":"…","updated_at":"2026-11-06T12:00:00Z"}],"next_cursor":null}` |
| `GET /api/v2/achievements` | 200 `{"items":[{"id":"first_video","title":"Første video","description":"Færdiggør en video","icon":"film","current":1,"target":1,"earned_at":"2026-11-06T12:00:00Z"}]}` |
| `GET /api/v2/agent-hub/events?after_revision=12` med `Accept: text/event-stream` | 200 SSE med `data: {"type":"hub_updated","revision":13}`. Klienten henter et nyt snapshot. Send `{"type":"resync_required"}` hvis historikken er udløbet. |

Agentstatus er `working`, `thinking`, `ready` eller `offline`. Sortér de seneste tre quests med den nyeste først. PC’en bør eje XP-regler, badgeoptjening og tidszonen for streaks. Filtrér tokens, rå værktøjsargumenter og interne filstier fra historik og hukommelse. Brug de eksisterende jobs som den autoritative videokø.
