# Nye links: vurdering og lokal implementeringsstatus

**Opdatering.** PocketPal-hukommelseskontrol og Lottie er tilføjet i iPhone-koden. En valgfri CrewAI Flow er koblet til CodeBatch og prøvet i et isoleret miljø med simulerede modelsvar. Godot kører som separat PC-projekt med gennemført prøve af hex- og voxelvisning. Luanti er stadig et alternativ, hvis en mod-baseret verden senere bliver ønsket. Se `FADEDAI-ROADMAP.md` for testresultater og åbne punkter. Vurderingen herunder beskriver udgangspunktet før ændringerne.

## Prioritering

1. **PocketPal AI**: forbedr den eksisterende lokale modelvej før flere nye modeller. Repoets `src/hooks/useMemoryCheck.ts`, `src/services/deviceRules/` og `src/services/agent/AgentRunner.ts` er relevante konkrete steder at undersøge til hukommelseskontrol, enhedskompatibilitet og værktøjssløjfen. README beskriver GGUF/llama.cpp, lokale stemmer, Whisper og værktøjer. FadedAI har allerede bl.a. `GGUFPhoneRuntime.swift`, `GGUFModelDownloads.swift`, `GGUFModelsView.swift` og `PhoneModelServer.swift`; roadmapens tidligere 1–17 er ikke bevis for, at alle telefonfunktioner er testet. Intet nyt kopieret fra PocketPal i denne gennemgang.
2. **Lottie iOS**: egnet til små status-/tomtilstandsanimationer. `Sources/Public/Animation/LottieView.swift` og `Sources/Public/Configuration/ReducedMotionOption.swift` er integrationspunkter. Brug eksisterende reduceret bevægelse og pausér usynlige animationer. Kan supplere BorderBeam; erstatter hverken maskottens eksisterende portrætter eller landsbyens karakterrig. README anbefaler den mindre `airbnb/lottie-spm`-pakke. Apache-2.0. Ikke tilføjet som dependency endnu.
3. **CrewAI**: Python-agentroller, samarbejde og styrede arbejdsgange. Relevant på PC, men overlapper FadedAIs `agent_workflows.py`, `code_batch.py` og botjob samt tidligere LangGraph-templateforslag. Ingen anden agentmotor sættes ind automatisk; kø, idempotens, brugerens godkendelser og privatliv skal bevares. MIT. Ikke installeret.
4. **Godot**: MIT-licenseret 2D/3D-motor med iOS-eksport. Mit forslag ved en senere større grafisk ombygning af Landsbyen. En motor er ikke færdige bygninger, bots, kirkegård eller tilsluttede AI-opgaver. Det kræver projekt/scene, assets og en bridge til eksisterende agenttilstand; ikke et drop-in-SwiftUI-kort. Ingen nuværende landsby erstattet.
5. **Luanti**: voxel-motor med mods og verdener, LGPL-2.1+. Overlapper Godot som verdensmotor og de tidligere voxelidéer. Vælg den kun, hvis voxel/mod-verden er målet; læg ikke både Godot og Luanti ind i iPhone-appen uden et konkret behov. Ikke installeret.

## Kilder

- https://github.com/a-ghorbani/pocketpal-ai
- https://github.com/airbnb/lottie-ios
- https://github.com/crewAIInc/crewAI
- https://github.com/godotengine/godot
- https://github.com/luanti-org/luanti

README og repo-metadata gennemlæst. Musikvalget og caststatus er dokumenteret i `MUSIC-AND-CAST.md`. Dette dokument er en prioritering og overlapliste, ikke en liste over nye færdige funktioner.
