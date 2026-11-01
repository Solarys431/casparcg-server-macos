# Contribuire

[English](CONTRIBUTING.md) · **Italiano**

Grazie dell'aiuto a CasparCG Server per macOS. I canali sono tre, ognuno per una cosa sola:

| Che cosa | Dove |
|---|---|
| Un difetto, o un suggerimento | le [Issues](../../issues): una per problema, dopo aver cercato se c'è già |
| Una correzione | una [pull request](../../pulls) su `main` |
| Una vulnerabilità | **solo per mail**, a **info@danielecappello.com**, mai in una issue pubblica ([SECURITY.md](SECURITY.md)) |

Un difetto che capita anche con una build non modificata del progetto originale, su Windows o Linux, va segnalato
[al progetto originale](https://github.com/CasparCG/server/issues). Le domande su come si usa CasparCG trovano
risposta nel [forum di CasparCG](https://casparcgforum.org/).

## Che cosa serve in una segnalazione

Senza queste informazioni un difetto su un Mac raramente si riproduce. Il modulo delle issue le chiede una per una.

1. Il chip e la memoria del Mac, dal menu Apple → Informazioni su questo Mac (per esempio *Apple M4, 16 GB*).
2. La versione di macOS (per esempio *26.6.2*).
3. La release (per esempio `v2.6.0-macos.3`) e la risposta a `VERSION` in AMCP (per
   esempio `2.6.0 1a2b3c4d5 Dev`). Dal Terminale: `(printf 'VERSION\r\n'; sleep 1) | nc 127.0.0.1 5250`.
4. Il driver Vulkan, KosmicKrisp o MoltenVK, che il registro indica all'avvio nella riga `Vulkan driver: …`.
5. I passi che portano al problema: i comandi AMCP in ordine, il `casparcg.config` (senza password), il tipo di
   media (codec, risoluzione, cadenza) e l'uscita (schermo, file, SRT, NDI…).
6. Che cosa è successo e che cosa ci si aspettava.
7. Il registro del server di quella sessione, da `~/Library/Application Support/CasparCG Server/log/`
   (o dal `log-path` della propria configurazione). Per un crash, anche il rapporto in Console → Rapporti di arresto
   anomalo (un file `casparcg-….ips`, in `~/Library/Logs/DiagnosticReports/`).

## Pull request

- Un ramo da `main`, un argomento per pull request, e messaggi di commit come quelli che ci sono: `fix(macos): …`,
  `feat(image): …`, `build(macos): …`, `docs: …`.
- Si costruiscono le dipendenze con `tools/macos/build-deps.sh <cartella>`, poi il server con
  `tools/macos/build.sh <cartella>`, e si prova quello che si è cambiato su un Mac vero. Nella pull request si
  dice su quali Mac e con quale driver, che cosa si è eseguito e che cosa si è misurato.
- Una modifica che tocca i pixel deve lasciare l'uscita del mixer Vulkan uguale a quella del mixer OpenGL di Windows
  e Linux. Va mostrato il confronto, con colori dai canali tutti diversi (un grigio nasconde i canali
  scambiati).
- Una dipendenza cambia in `tools/macos/deps.list` o in `src/CMakeModules/Bootstrap_Mac.cmake` (versione, indirizzo,
  SHA-256); una patch va in `tools/macos/patches/`, con una riga che dice perché.
- Il codice scritto con l'aiuto dell'IA è benvenuto, purché lo si sia eseguito e provato e la pull request lo dichiari.
- Il contributo è distribuito con la **GNU General Public License, versione 3 o successiva**, come il progetto.

## Comportamento

Qui tutti seguono il [codice di condotta](CODE_OF_CONDUCT.md).
