# 0001. Secure Enclave в симуляторе

- **Пункт:** SPEC §9.1, `[проверить: доступность Secure Enclave в симуляторе]`.
- **Этап:** 0. **Дата:** 2026-10-19.
- **Статус:** вывод по документации записан; эмпирическая проверка — тест `SecureEnclaveAvailabilityTests` при первом прогоне на Mac (Xcode 27.0, iOS Simulator 27.0).

## Вопрос

Можно ли в симуляторе создавать ключи в Secure Enclave и подписывать ими? От ответа зависит, когда клиент берёт `SoftwareKeyProvider` (SPEC §9.1: программный P-256 ключ, только Debug).

## Что говорит документация

- Apple, «Protecting keys with the Secure Enclave»: Secure Enclave «requires hardware support. Only iOS devices with an A7 or later processor, or a Mac with the Touch Bar and Touch ID or with an M1 or later processor support this feature»; работает только с P-256; ключ создаётся внутри Secure Enclave и наружу не выходит. Про симулятор документ не говорит. <https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>
- Apple Developer Forums, ответ инженера Apple (Quinn): проверять доступность нужно через `SecureEnclave.isAvailable` из CryptoKit; на старых системах — попыткой создать ключ (ошибка `errSecUnimplemented`). <https://developer.apple.com/forums/thread/723176>
- Явного утверждения Apple о симуляторе я не нашёл. Поэтому факт закрывается прогоном на Xcode 27, а код от него не зависит (ниже).

## Решение

1. Выбор реализации — во время выполнения, по `SecureEnclave.isAvailable`, а не по `targetEnvironment(simulator)`:
   - `true` → `SecureEnclaveKeyProvider` (и в Debug, и в Release);
   - `false` в Debug → `SoftwareKeyProvider`;
   - `false` в Release → ошибка «устройство не поддерживается», без программного ключа. В Release-сборке `SoftwareKeyProvider` не компилируется (`#if DEBUG`).
2. Тест `SecureEnclaveAvailabilityTests` фиксирует наблюдаемое значение в симуляторе (ожидание: `false`). Если на Xcode 27 окажется `true`, тест упадёт, и этот документ надо обновить: тогда путь Secure Enclave можно гонять и в симуляторе.
3. Физическая проверка на iPhone остаётся обязательной для этапов 1, 4, 6 (SPEC §9.1), независимо от результата.
