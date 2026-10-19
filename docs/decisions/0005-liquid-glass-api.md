# 0005. Liquid Glass: API в iOS 27 SDK

- **Пункт:** PLAN, этап 2, `[проверить]`: актуальные API Liquid Glass в iOS 27 SDK (SPEC §8.1, `design/DESIGN.md`).
- **Этап:** 2. **Дата:** 2026-10-19.
- **Статус:** закрыт.

## Вопрос

Какими API SwiftUI в iOS 27 делать стеклянные карточки, кнопки и шапку Home, чтобы стекло было системным, а не нарисованным вручную (DESIGN.md: «CSS-значения из HTML не переносить»)?

## Источник

Публичный интерфейс SwiftUI в iOS 27 SDK из Xcode 27: `SwiftUI.framework` и `SwiftUICore.framework`, файлы `Modules/*.swiftmodule/arm64e-apple-ios.swiftinterface`. Документация Apple: «Applying Liquid Glass to custom views» <https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views>.

## Что есть в SDK

Все API ниже доступны с iOS 26 (`@available(iOS 26.0, …)`, `visionOS unavailable`). В iOS 27 SDK у них нет новых перегрузок и нет пометок `deprecated`.

| API | Модуль | Для чего |
|---|---|---|
| `View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())` | SwiftUICore | стеклянная подложка своего вида в заданной форме |
| `Glass.regular`, `.clear`, `.identity`; `.tint(Color?)`, `.interactive(Bool)` | SwiftUICore | вариант стекла, цветной оттенок, реакция на касание |
| `GlassEffectContainer(spacing:content:)` | SwiftUICore | несколько стеклянных форм рядом: общий рендер, слияние форм при сближении |
| `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)`, `glassEffectTransition(_:)` (`.matchedGeometry`, `.materialize`, `.identity`) | SwiftUICore | анимации появления и слияния стекла |
| `ButtonStyle .glass`, `.glass(Glass)`, `.glassProminent` | SwiftUI | стеклянные кнопки; `glassProminent` — основная кнопка с акцентом |
| `ToolbarSpacer`, `tabBarMinimizeBehavior(_:)`, `scrollEdgeEffectStyle(_:for:)`, `backgroundExtensionEffect()` | SwiftUI | системный таб-бар и тулбар со стеклом, края прокрутки |

Системные `TabView`, `NavigationStack` и тулбар получают Liquid Glass сами, без кода.

## Решение

- Карточки Home (метрики, Needs Attention, Active Agents, Last Activity) и плитки Quick Access — свой вид с `.glassEffect(.regular, in: .rect(cornerRadius:))`. Ряды карточек обёрнуты в `GlassEffectContainer`.
- Нажимаемые плитки — `Glass.regular.interactive()`. Основная кнопка — `.buttonStyle(.glassProminent)` с акцентным `tint`, обычные — `.buttonStyle(.glass)`.
- Таб-бар, навигация и кнопки тулбара (тема, настройки) — системные, стекло дают они сами.
- Цвет стекла не задаём. Акцент `#C8F560` идёт только в `tint` и в отдельные элементы (точка Online, основная кнопка), как требует DESIGN.md.
- Все компоненты лежат в одной библиотеке `RHClient/UI/`. На этапе 5 из неё же собираются компоненты страниц `rh.page/1`.

Расхождений со SPEC нет.
