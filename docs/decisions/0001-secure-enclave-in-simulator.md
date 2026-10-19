# 0001. Secure Enclave в симуляторе

- **Пункт:** SPEC §9.1, `[проверить: доступность Secure Enclave в симуляторе]`.
- **Этап:** 0. **Дата:** 2026-10-19.
- **Статус:** закрыт прогоном на Mac владельца 2026-10-19: Xcode 27.1 (27A9275), симулятор iPhone 17 Pro, iOS 27.0 (24A5423a), Apple silicon. `SecureEnclave.isAvailable == true`, а не `false`, как ожидал первый вариант теста.

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
2. Тест `SecureEnclaveAvailabilityTests` фиксирует наблюдаемое поведение симулятора. Первый вариант ждал `isAvailable == false` и упал. Теперь тест проверяет `isAvailable == true` и то, что ключ Secure Enclave в симуляторе создаётся, подписывает и подпись проверяется. Если на новом Xcode это изменится, тест упадёт, и документ надо обновить.
3. Физическая проверка на iPhone остаётся обязательной для этапов 1, 4, 6 (SPEC §9.1), независимо от результата.

## Что это меняет

- В симуляторе (на этом Mac) Debug-сборка выбирает `SecureEnclaveKeyProvider`, поэтому путь Secure Enclave проверяется тестами в симуляторе. Код выбора не меняется: он смотрит на `isAvailable` во время выполнения.
- `SoftwareKeyProvider` остаётся для Debug на машинах без Secure Enclave и для тестов, где нужен ключ с известным значением.
- Ключи с биометрией (`.biometryCurrentSet`) в симуляторе этим не проверены: это вопрос этапа 1 вместе с Face ID в симуляторе.

