# ReplixerMac — Telegram call detection PoC

Мінімальний CLI-експеримент: перевіряє, чи можна на macOS (Sonoma, 14.2+)
надійно виявити активний дзвінок Telegram тим самим принципом, що й Windows-
версія — "мікрофон і колонки використовує один і той самий процес" — але
через CoreAudio Process Object API (`kAudioHardwarePropertyProcessObjectList`,
`kAudioProcessPropertyIsRunningInput/Output`) замість реєстру + WASAPI.

Код писався і перевірявся на Windows-машині без компілятора Swift —
**збирати й тестувати потрібно на реальному Mac**.

## Запуск

```bash
swift run
```

Потім зателефонуйте через Telegram (голосовий чи відеодзвінок) — у консолі
має з'явитись `📞 Дзвінок почався`, а після завершення — `🔚 Дзвінок закінчився`.

## Відомі обмеження цього підходу (з дослідження sonicflow / Apple forums)

- Потребує macOS 14.2+; на 14.0–14.1 список процесів буде порожній.
- HAL property listeners для `IsRunningInput/Output` ненадійні — тому тут
  усе побудовано на поллінгу раз/сек, без підписки на listener.
- Якщо Telegram Desktop (Qt-версія) реєструє аудіо через дочірній/helper-
  процес, а не головний — `NSRunningApplication(processIdentifier:)` може
  його не знайти за іменем. Якщо PoC не побачить дзвінок, перша підозра —
  саме це; тоді доведеться матчити по PID через `lsof`/`ps` дерево процесів
  замість `NSRunningApplication`.
- Дозволів мікрофона/entitlements не потребує — це лише читання стану,
  без реального захоплення аудіо.
