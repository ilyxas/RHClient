# 0002. Face ID: один LAContext на сессию и смена биометрии

- **Пункт:** PLAN, этап 1, `[проверить]`: переиспользование `LAContext` для подписи ключом Secure Enclave (`kSecUseAuthenticationContext`), поведение `.biometryCurrentSet` при смене биометрии и как это распознать.
- **Этап:** 1. **Дата:** 2026-10-19.
- **Статус:** закрыт по документации. Тип ошибки при подписи ключом, который стал недоступен, проверяется на iPhone при приёмке этапа 1 (SPEC §9.1).

## Вопрос

SPEC §4.1 требует:
- `normal`: Face ID при открытии приложения, затем подписи без новых запросов, пока приложение активно; после 5 минут в фоне сброс;
- `critical`: свежий Face ID на каждую подпись;
- флаги всех ключей: `.privateKeyUsage` + `.biometryCurrentSet`, без fallback на код;
- после смены биометрии ключи недоступны, приложение показывает Pairing lost (§4.2).

Нужно понять три вещи. Можно ли один раз пройти Face ID и подписывать дальше без новых запросов? Что происходит с ключом после смены биометрии? Как отличить такой ключ от отмены Face ID пользователем?

## Что говорит документация

- `kSecUseAuthenticationContext`: «If this key is specified with a context that has been previously authenticated, the operation will succeed without asking user for authentication. If this key is specified with a context that has not been previously authenticated, the system attempts authentication on the context. If successful, the context may be reused in subsequent keychain operations.» <https://developer.apple.com/documentation/security/ksecuseauthenticationcontext>
- WWDC22 «Streamline local authorization flows» (10108): «By binding the LAContext to our private key reference, we ensure that executing the signature operation will not trigger another authentication … no additional user interactions will be required for future signatures until the LAContext is invalidated.» <https://developer.apple.com/videos/play/wwdc2022/10108/>
- CryptoKit: `SecureEnclave.P256.Signing.PrivateKey(compactRepresentable:accessControl:authenticationContext:)` и `init(dataRepresentation:authenticationContext:)` принимают `LAContext`. Это тот же механизм, только без SecItem-запроса. <https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey>
- `LAContext.touchIDAuthenticationAllowableReuseDuration` нам не подходит. Он засчитывает только недавнюю разблокировку устройства по Touch ID: «this grace period applies specifically to device unlock with Touch ID, not keychain retrieval authentications». <https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id>
- `SecAccessControl.h`, `kSecAccessControlBiometryCurrentSet`: «When fingers are added or removed, the item is invalidated. When Face ID is re-enrolled this item is invalidated.» Для `BiometryAny` наоборот: «Item is still accessible by Face ID if user is re-enrolled.» <https://opensource.apple.com/source/Security/Security-58286.51.6/keychain/SecAccessControl.h.auto.html>
- Код ошибки у недействительного элемента от версии к версии разный. На iOS 14 это был `errSecItemNotFound`, на iOS 15 стал `errSecAuthFailed`, и тот же `errSecAuthFailed` приходит, если приложение ушло в фон во время Face ID (Apple Developer Forums, 2021). <https://developer.apple.com/forums/thread/690778>
- `LAContext.domainState` / `evaluatedPolicyDomainState` для обнаружения смены биометрии ненадёжен. Quinn (Apple DTS), октябрь 2025: «Apple reserves the right to change such values extra-ordinarily — that is, without the user specifically changing their biometrics — and your app should be designed to handle that gracefully.» <https://developer.apple.com/forums/thread/802782>

## Решение

1. **Ключи.** Создаются через CryptoKit `SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl:authenticationContext:)`, `SecAccessControl` = `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `[.privateKeyUsage, .biometryCurrentSet]`. В Keychain хранится `dataRepresentation` (зашифрованная ссылка на ключ, расшифровать её может только Secure Enclave этого устройства) как generic password с `…ThisDeviceOnly`. Сам ACL проверяет Secure Enclave при подписи.
2. **Сессия `normal`.** При открытии приложения создаётся один `LAContext`, у которого `localizedFallbackTitle = ""` (без кнопки кода). Он явно проходит `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`. Затем этот контекст передаётся в `init(dataRepresentation:authenticationContext:)` для каждой подписи `normal`. Через N минут в фоне (по умолчанию 5, настройка в Settings, SPEC §8.7) контекст получает `invalidate()`, при возвращении нужен новый Face ID.
3. **`critical`.** На каждую подпись создаётся новый `LAContext`, проходит `evaluatePolicy` с причиной, которую видит пользователь (что именно подписывается), подписывает и сразу получает `invalidate()`. Контекст сессии для `critical` не используется никогда.
4. **Как распознать недоступный ключ.** Face ID всегда проходит отдельным шагом до подписи. Тогда:
   - `evaluatePolicy` упал с `userCancel` / `appCancel` / `systemCancel` → операция отменена, ключи не трогаем;
   - `biometryNotEnrolled` / `biometryNotAvailable` / `passcodeNotSet` → состояние «нужен Face ID» с объяснением, ключи не трогаем;
   - `evaluatePolicy` успешен, а загрузка ключа или подпись падает → ключ недоступен (смена биометрии, восстановление на другое устройство) → **Pairing lost**;
   - в Keychain нет `dataRepresentation` → **Pairing lost**.

   Код ошибки CryptoKit / Security в разборе не участвует, он меняется между версиями iOS. `domainState` тоже не участвует: Apple прямо пишет, что значение может измениться без смены биометрии.
5. **Слой.** В RHKit `MessageSigner` получает уровень ключа и сам решает, где показать Face ID. Сессия и таймер фона живут в приложении, RHKit о них не знает.

## Что проверить на устройстве

- Приёмка этапа 1 на iPhone: Face ID при открытии; ping и статус без повторного Face ID; Revoke спрашивает Face ID каждый раз.
- Смена биометрии на iPhone (сброс и повторная настройка Face ID). После неё приложение показывает Pairing lost, не падает и не уходит в бесконечные запросы. Записать сюда, какую ошибку отдала подпись.
- В симуляторе «Features → Face ID → Enrolled» выключить и включить. Если симулятор так моделирует смену набора, этот путь покроет UI-тест. Если нет, остаётся только проверка на iPhone.
