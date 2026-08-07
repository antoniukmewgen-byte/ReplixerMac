import Foundation

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss"

func timestamp() -> String { formatter.string(from: Date()) }

// Phase 1.6: sweep any recordings left in a `.inprogress` state by a crash
// or force-quit during a previous run, before doing anything else.
FileNaming.cleanupStalePartialFiles()

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

if CommandLine.arguments.contains("--mic-smoke-test") {
    print("[\(timestamp())] Крок A (1.2): смоук-тест мікрофона.")
    // requestRecordPermission's completion is async (may land on any queue),
    // so the smoke test itself calls exit(0) when it's actually done —
    // we just keep the run loop alive here so that completion can fire.
    MicrophoneSmokeTest.run()
    RunLoop.main.run()
}

print("[\(timestamp())] Слухаю дзвінки Telegram... (Ctrl+C для виходу)")

let coordinator = CallRecordingCoordinator()
let monitor = TelegramCallMonitor()
monitor.onCallStarted = { name in
    print("[\(timestamp())] 📞 Дзвінок почався — \(name)")
    Task { await coordinator.callStarted(processName: name) }
}
monitor.onCallEnded = { name in
    print("[\(timestamp())] 🔚 Дзвінок закінчився — \(name)")
    Task { await coordinator.callEnded(processName: name) }
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
        exit(0)
    }
}

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { handleShutdownSignal("SIGINT (Ctrl+C)") }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { handleShutdownSignal("SIGTERM") }
sigtermSource.resume()

RunLoop.main.run()
