# 0003. Заголовки подписи на upgrade-запросе WebSocket

- **Пункт:** PLAN, этап 1, `[проверить]`: заголовки на upgrade-запросе `URLSessionWebSocketTask` (нужно для `ws.open`).
- **Этап:** 1. **Дата:** 2026-10-19.
- **Статус:** закрыт по документации. Подтверждается UI-тестом против dev rh-core: hello приходит, revoke закрывает сокет с кодом 4403.

## Вопрос

`/v1/ws` открывается подписанным GET (`op: "ws.open"`, пустое тело) с заголовками `X-RH-Auth` / `X-RH-Sig` (contracts/api/openapi.yaml). Нужно, чтобы `URLSessionWebSocketTask` отправил эти заголовки в HTTP-рукопожатии без изменений. Ещё нужно, чтобы клиент увидел нестандартный код закрытия 4403.

## Что говорит документация

- `URLSession.webSocketTask(with: URLRequest)`: «You can modify the request’s properties prior to calling resume() on the task. The task uses these properties during the HTTP handshake phase. … The custom HTTP headers provided by the client remain unchanged for the handshake with the server.» <https://developer.apple.com/documentation/foundation/urlsession/websockettask(with:)>
- `URLSessionWebSocketTask.CloseCode` импортирован из `NS_ENUM` (`NSURLSessionWebSocketCloseCode : NSInteger`), а такой enum в Swift хранит и значения вне списка. Поэтому `closeCode.rawValue == 4403` доступен и в `urlSession(_:webSocketTask:didCloseWith:reason:)`, и в `task.closeCode`. <https://developer.apple.com/documentation/foundation/urlsessionwebsockettask>

## Решение

- `CoreClient.eventStreamRequest()` делает challenge и подписывает `ws.open`. Он возвращает `URLRequest` со схемой `wss` (`ws` только для dev `http://127.0.0.1`) и nonce, которым ядро подписывает кадры. Приложение создаёт задачу через `webSocketTask(with:)` с этим запросом.
- Кадры проверяет `EventFrameReader` (подпись, `payload.seq == seq`, порядок 1, 2, 3, …). Кадр, который не прошёл проверку, закрывает соединение. Дальше приложение действует как при обрыве: переподключается и перечитывает состояние по REST.
- При закрытии с кодом 4403 соединение получает состояние Pairing lost. Если upgrade не удался (ответ не 101), причину узнаём подписанным `GET /v1/status`, как договорено с сервером.
