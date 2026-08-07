import Foundation

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss"

func timestamp() -> String { formatter.string(from: Date()) }

// Phase 1.6: sweep any recordings left in a `.inprogress` state by a crash
// or force-quit during a previous run, before doing anything else.
FileNaming.cleanupStalePartialFiles()

// Phase 2.1: load (or bootstrap, on first run) persisted settings. No UI to
// edit these yet (Phase 7) — logging the resolved value + file path here so
// hand-editing settings.json has an obvious way to confirm it took effect.
print("[\(timestamp())] Налаштування: manager=\"\(AppSettings.shared.managerName)\" (файл: \(AppSettings.store.url.path))")

// Phase 2.2: log how many past recordings are already known, so a fresh
// run makes it obvious whether recordings.json loaded correctly.
print("[\(timestamp())] Історія записів: \(RecordingHistory.shared.entries.count) запис(ів) у \(RecordingHistory.store.url.path)")

// Phase 2.2 (fix): JSON-level counterpart of the .inprogress file sweep
// above — reconcile any entry left in `.recording` status by a crash/
// `kill -9` on a previous run to `.error`, so it doesn't sit there looking
// like a call that's still going, forever.
let reconciledCount = RecordingHistory.shared.reconcileDanglingRecordings()
if reconciledCount > 0 {
    print("[\(timestamp())] ⚠️ Знайдено \(reconciledCount) запис(ів) історії, залишених у статусі \"recording\" після аварійного завершення — позначено як \"error\".")
}

if CommandLine.arguments.contains("--tap-smoke-test") {
    print("[\(timestamp())] Крок B: смоук-тест ProcessTap. Шукаю процес Telegram у CoreAudio HAL...")
    if let objectID = ProcessTapSmokeTest.findTelegramProcessObjectID() {
        ProcessTapSmokeTest.run(processObjectID: objectID)
    } else {
        print("[\(timestamp())] ❌ Процес Telegram не знайдено у списку CoreAudio-процесів. Переконайтесь, що Telegram запущено (бажано під час активного дзвінка).")
    }
    exit(0)
}

if CommandLine.arguments.contains("--tap-aggregate-smoke-test") {
    print("[\(timestamp())] Крок C: смоук-тест агрегованого пристрою + IOProc. Шукаю процес Telegram у CoreAudio HAL...")
    if let objectID = ProcessTapSmokeTest.findTelegramProcessObjectID() {
        AggregateTapSmokeTest.run(processObjectID: objectID)
    } else {
        print("[\(timestamp())] ❌ Процес Telegram не знайдено у списку CoreAudio-процесів. Переконайтесь, що Telegram запущено (бажано під час активного дзвінка).")
    }
    exit(0)
}

if CommandLine.arguments.contains("--tap-file-write-smoke-test") {
    print("[\(timestamp())] Крок D: смоук-тест запису у .wav. Шукаю процес Telegram у CoreAudio HAL...")
    if let objectID = ProcessTapSmokeTest.findTelegramProcessObjectID() {
        TapFileWriteSmokeTest.run(processObjectID: objectID)
    } else {
        print("[\(timestamp())] ❌ Процес Telegram не знайдено у списку CoreAudio-процесів. Переконайтесь, що Telegram запущено (бажано під час активного дзвінка).")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dual-stream-smoke-test") {
    print("[\(timestamp())] Крок 1.3: смоук-тест агрегованого пристрою (tap + мікрофон). Шукаю процес Telegram у CoreAudio HAL...")
    if let objectID = ProcessTapSmokeTest.findTelegramProcessObjectID() {
        DualStreamCapture.run(processObjectID: objectID)
    } else {
        print("[\(timestamp())] ❌ Процес Telegram не знайдено у списку CoreAudio-процесів. Переконайтесь, що Telegram запущено (бажано під час активного дзвінка).")
    }
    exit(0)
}

if CommandLine.arguments.contains("--mix-smoke-test") {
    print("[\(timestamp())] Крок 1.4: смоук-тест мікшування + кодування в AAC. Шукаю процес Telegram у CoreAudio HAL...")
    if let objectID = ProcessTapSmokeTest.findTelegramProcessObjectID() {
        AudioMixerEncoder.run(processObjectID: objectID)
    } else {
        print("[\(timestamp())] ❌ Процес Telegram не знайдено у списку CoreAudio-процесів. Переконайтесь, що Telegram запущено (бажано під час активного дзвінка).")
    }
    exit(0)
}

if CommandLine.arguments.contains("--list-audio-processes-smoke-test") {
    print("[\(timestamp())] Крок Phase 3 діагностика: список CoreAudio-процесів з активним input/output.")
    AudioProcessListSmokeTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--telegram-login-smoke-test") {
    print("[\(timestamp())] Крок Phase 4.1: смоук-тест авторизації Telegram (TDLib). Якщо це перший запуск — знадобиться ввести номер телефону, код підтвердження і, можливо, пароль 2FA.")
    Task {
        let telegramAuthClient = TelegramAuthClient()
        do {
            try await telegramAuthClient.login()
            print("[\(timestamp())] ✅ Смоук-тест завершено — авторизація Telegram пройшла успішно.")
        } catch TelegramAuthError.missingCredentials {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнені telegramApiId/telegramApiHash — додай їх (значення з https://my.telegram.org) і спробуй знову.")
        } catch {
            print("[\(timestamp())] ❌ Смоук-тест провалився: \(error)")
        }
        // Must close TDLib's client cleanly before exit(0) below — killing
        // the process while its background td_receive thread is still
        // running crashes with SIGSEGV (confirmed on a real run).
        telegramAuthClient.shutdown()
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--mic-smoke-test") {
    print("[\(timestamp())] Крок A (1.2): смоук-тест мікрофона.")
    // requestRecordPermission's completion is async (may land on any queue),
    // so the smoke test itself calls exit(0) when it's actually done —
    // we just keep the run loop alive here so that completion can fire.
    MicrophoneSmokeTest.run()
    RunLoop.main.run()
}

let watchedMessengers = SupportedMessenger.allCases.map(\.rawValue).joined(separator: ", ")
print("[\(timestamp())] Слухаю дзвінки (\(watchedMessengers))... (Ctrl+C для виходу)")

let coordinator = CallRecordingCoordinator()
let monitor = CallMonitor()
monitor.onCallStarted = { messenger, name in
    print("[\(timestamp())] 📞 Дзвінок почався — \(messenger.rawValue) (\(name))")
    Task { await coordinator.callStarted(messenger: messenger, processName: name) }
}
monitor.onCallEnded = { messenger, name in
    print("[\(timestamp())] 🔚 Дзвінок закінчився — \(messenger.rawValue) (\(name))")
    Task { await coordinator.callEnded(messenger: messenger, processName: name) }
}
monitor.start()

// Phase 1.6: catch Ctrl+C (SIGINT) and `kill` (SIGTERM, the default signal)
// so an active recording gets a clean stop() — which renames its
// .inprogress file to the real name — instead of being killed mid-write.
// SIGKILL (`kill -9`) can't be caught by any process; that residual case is
// handled by FileNaming.cleanupStalePartialFiles() on the next startup.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

func handleShutdownSignal(_ signalName: String) {
    print("[\(timestamp())] Отримано \(signalName) — коректно завершую (зупиняю активний запис, якщо є)...")
    Task {
        await coordinator.shutdown()
        // Phase 2.1/2.2: flush any debounced-but-not-yet-written settings
        // or history changes before exiting, same reasoning as the
        // recording's clean stop() above — don't let a pending write get
        // lost to shutdown.
        AppSettings.shared.flush()
        RecordingHistory.shared.flush()
        exit(0)
    }
}

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { handleShutdownSignal("SIGINT (Ctrl+C)") }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { handleShutdownSignal("SIGTERM") }
sigtermSource.resume()

// Testing aid only: Xcode's Run console doesn't forward Ctrl+C as a real
// SIGINT the way a Terminal window does (there's no TTY behind it), so
// there'd be no way to exercise the graceful-shutdown path while running
// from Xcode. As a stand-in, listen for a line typed into the Xcode
// console — `q` + Enter — and route it through the exact same shutdown
// path as SIGINT/SIGTERM. Harmless when run from a real Terminal too,
// since Ctrl+C there triggers SIGINT directly and this just sits idle
// waiting on stdin.
DispatchQueue.global(qos: .userInitiated).async {
    print("[\(timestamp())] (тест) введи 'q' + Enter у консолі Xcode, щоб коректно завершити роботу без SIGINT.")
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "q" {
            handleShutdownSignal("клавіатура (q)")
            break
        }
    }
}

RunLoop.main.run()
