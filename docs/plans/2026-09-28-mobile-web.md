# Игра с телефона в браузере — план

## Передача в Claude Code — 2026-11-21 (читать первой)

Это актуальное продолжение раздела «Состояние на 2026-10-03» ниже. Исторические
записи и примеры кода дальше описывают ход работы; исходники и этот раздел важнее
устаревших шагов плана. Пользователь попросил сохранить работу **в этой worktree**,
чтобы продолжить в другой сессии Claude Code. Сейчас нужна передача, а не новая
разработка, новый дизайн или публикация.

### Где продолжать и что прочитать

- Worktree: `/Users/proshik/.superconductor/worktrees/base13/sc-paired-niobium-98d8`.
- Ветка: `feat/mobile-web-game`, исходная база `a72d740`.
- До записи этой передачи дерево было чистым; последний коммит — `34ef65a`.
- Прочитать `AGENTS.md` целиком, эту передачу, следующий раздел состояния и
  `docs/specs/2026-09-28-mobile-web-design.md`. Актуальные личные правила пользователя
  находятся в `/Users/proshik/.agents/memories/personal-preferences.md`.
- Пользователю отвечать по-русски, просто. Не спрашивать заново об уже согласованном.
- TDD: падающий тест → минимальный код → зелёный `./tools/test.sh` → локальный коммит
  на английском (`fix:`, `feat:`, `test:`, `docs:`, `chore:`), без Co-Authored-By.
- `game/core/`, `Golden.EXPECTED`, `game/tests/core/test_regression.gd` не менять.
- Перед новой библиотекой или собственной заменой известной библиотеки предложить
  варианты пользователю. В этих правках новых зависимостей нет.
- Push, MR, релиз, внешние сообщения не разрешены. Нужны отдельное подтверждение,
  зелёный тест и показанный отчёт. Саму передачу никуда не публиковать.

### Что сделано и одобрено

Задачи 1–9 плана реализованы. Задача 10 (живые проверки и документы) не закрыта.

- Утверждён вариант А: вертикальная мобильная раскладка, увеличенное квадратное поле,
  показатели ENEMY / 1P / STAGE одной строкой под ним. На компьютере показатели справа
  и серая рамка сохранены. Поворот телефона поддержан.
- Панель управления: неподвижный крест слева, START посередине, красная FIRE справа;
  анимация нажатия, удержания и отпускания через штатный Tween. START не меняет
  подпись на PAUSE; пауза — отдельное меню. Отступ подписи START увеличен по просьбе
  пользователя. Мобильный текст меню, паузы и сообщений над полем увеличен до масштаба 2.
- Стрелки работают от неподвижного тапа, удержания и перетаскивания. Исправлен
  VirtualJoystick: FIXED вместо FOLLOWING, центр совпадает с крестом, быстрый тап
  сохраняется до следующего шага; отмена касания не создаёт новое нажатие.
- Пользователь одобрил вид и подтвердил совместную игру двух пользователей
  телефон ↔ компьютер через QUICK GAME.
- Ощущение пропусков FIRE разобрано: при частых тапах кнопка анимировалась, но у
  обычного танка разрешена одна пуля в полёте. 200 диагностических тапов дошли до
  сетевого ввода, в том числе при удержании стрелки; 60 снятий удержания FIRE — до
  локального. После объяснения и повторной проверки пользователь: «да, ок, работает».
  Код стрельбы и ядро не менялись; дефект FIRE не подтверждён.
- Вибрацию решили пока не добавлять. Опыт `tools/haptics-check.html` на настоящем
  iPhone показал одинаковое поведение Safari и Chrome: нативный switch даёт толчок
  только при отпускании короткого тапа, после удержания — нет. Пользователь согласился
  оставить анимацию без вибрации. Библиотека не подключалась, в игру опыт не встроен.

### Последние правки ввода кода комнаты

Пользователь сообщил, что клавиатура не появляется. Настоящее HTML-поле стояло
у верха страницы, а под ROOM CODE рисовался другой, неинтерактивный код. Пользователь
подтвердил: было непонятно, куда нажать.

- `8540014`: поле `CodeField` перемещено прямо под ROOM CODE, в белую рамку;
  дублирующий рисунок убран только там, где открыто HTML-поле. Пустое поле показывает
  TAP HERE, ниже TAP TO TYPE. Поле следует за canvas при повороте и изменении размера.
  Десктоп сохраняет старый ввод клавиатурой без HTML-поля.
- `cb9b555`: по просьбе пользователя TAP HERE исчезает при фокусе, в пустом поле
  остаётся курсор; после потери фокуса подсказка возвращается.
- Браузерный регрессионный тест `tools/test_code_field.mjs` сначала падал на касании
  canvas вместо поля, затем прошёл. Проверяет настоящее касание и фокус, подсказку,
  редактирование, короткий/полный код, поворот, сокращение высоты, плотность пикселей 3,
  отправку, выход и отсутствие дубликатов поля. Он не доказывает клавиатуру iOS.
- После этих правок пользователь получил NO SUCH ROOM при ручном наборе. Причина
  **не установлена**, не считать её исправленной или объяснённой опечаткой. Комната
  FR2EVA тогда существовала, сервер и создатель были живы. Контрольный ввод FR2EVA
  через пустое мобильное HTML-поле во втором Chrome дал исходящий code=FR2EVA,
  ответ ok=true, slot=1; оба браузера сыграли и завершили уровень на tick=2778.
- Пользователю предложили новую комнату X37JQK со ссылкой, где код уже заполнен,
  чтобы отделить ввод от подключения. Подтверждения результата не было.
- 2026-11-16 по просьбе «запусти опять» подняли `just phone` и создали 2WEPKE на
  новом тогда адресе `192.168.31.130`. Пользователю дали ссылку с кодом и предложили
  нажать FIRE. Результата с телефона не поступило. На этом остановились.

### Проверки и артефакты

Последний полный прогон выполнялся **2026-10-05**, при сборке правки из `cb9b555`:
628/628 GUT, Go, изоляция ядра/сервера и ресурсы зелёные. Веб-экспорт проверен на
35 уровней. Это исторический результат, сегодня тесты заново не запускались.
При запуске 2026-11-16 исходники не меняли, использовали тот же веб-экспорт.

Полезные файлы (часть игнорируется Git, доступна только в этой worktree):

- `.build/mobile-design/field-focus-build.log` — последний полный тест и сборка.
- `.build/mobile-design/field-focus-red.log`, `field-focus-green.log` — проверка подсказки.
- `.build/mobile-design/code-red.log`, `code-green.log` — проверка позиции поля.
- `.build/mobile-design/join-code.log`, `room-entered-code.png` — контрольный вход FR2EVA.
- `.build/mobile-design/fire-probe.gd`, `fire-all.log` — диагностика FIRE и полный тест.
- `.superpowers/sdd/2026-09-28-mobile-web/phone.log` — старый журнал сервера с парой
  телефон/компьютер и комнатой FR2EVA. Ноябрьский запуск писал в терминал, не в этот лог.
- `tools/test_code_field.mjs` и `tools/test_haptics_check.mjs` — сохранённые браузерные
  проверки без библиотек: Node со встроенным WebSocket, отдельный браузер по CDP.
  Запуск: `node tools/test_code_field.mjs <browser-CDP-WS> <URL-игры>`.
- `.build/mobile-design/check-pair.mjs` — старый локальный интерактивный CDP-стенд.
  В нём захардкожен **старый** IP `192.168.31.120`: не запускать вслепую. Старые
  CDP-адреса, идентификаторы браузеров, процессов и терминальных сессий недействительны.

Ключевые коммиты: `42424fa` (вариант А), `f40d7e9` (стрелки/размер текста),
`0b8c877` (опыт вибрации), `8540014` (поле на месте кода), `cb9b555` (подсказка при
фокусе), `34ef65a` (доказательства контрольного входа). Коммиты документации между
ними сохраняют решения пользователя. Не откатывать эти решения к раннему плану.

### Стенд на момент передачи, 2026-11-21

- TCP 8443 **не слушается**: сервер сейчас выключен. В этой передаче его не запускали.
- Текущий IP по `ipconfig getifaddr en0`: **192.168.31.81**. Он может измениться снова.
- Коды FR2EVA, X37JQK, 2WEPKE — исторические, не давать их как рабочие. После нового
  запуска создать новую комнату и сверить код со свежим серверным журналом.
- `build/web/` существует, `index.pck` 541820 байт, время экспорта 2026-10-05 18:29.
- Для запуска из корня worktree: `just phone`. Без just — `./tools/phone.sh`.
  Скрипт берёт текущий Wi-Fi IP, обновляет mkcert-сертификат, собирает сервер и раздаёт
  имеющийся веб-экспорт по HTTPS на порту 8443. Чтобы пересобрать игру: `just phone --build`
  (сначала полный `./tools/test.sh`). Не открывать HTTP с телефона.
- Корневой сертификат mkcert уже ставили на iPhone. Не печатать и не коммитить ключи.
  Сертификаты лежат в `.build/phone/`, корневой — в каталоге `mkcert -CAROOT`.
- После старта проверить `https://<IP>:8443/health` с доверенным CA; отдельный браузер
  компьютера оставить открытым и активным на ожидании комнаты. Не трогать обычные
  пользовательские вкладки, не использовать один браузер с двумя скрывающимися вкладками.

### Живые проверки 2026-11-21

Стенд: `just phone` на `192.168.31.81:8443`, тот же веб-экспорт от 2026-10-05,
журнал сервера `.build/phone/relay-2026-11-21.log` (игнорируется Git). Вторым игроком
был отдельный headless Chrome компьютера со своим профилем.

- **Ссылка с кодом — прошла.** Первая попытка (комната 8PXU3U) по журналу пришла из
  `web (chrome, macos)`, а не с телефона — её не засчитываем. Повтор: комната YAFEKA,
  `https://…/?room=YAFEKA` на iPhone → FIRE; журнал: `web_ios (safari, ios)`, оба
  начали stage 1. Уровень закончился на такте 130 (через ~2 с), обе стороны назвали
  один и тот же такт; компьютер показал GAME OVER со счётом 0. Пользователь сказал
  «уровень идёт»; что произошло на телефоне, не выяснено — вероятно, разрушена база,
  но это не доказано.
- **Ручной ввод кода — прошёл.** Комната FM3ET4, NETWORK → JOIN ROOM → касание
  рамки. Пользователь: «клавиатура появилась, вошёл, уровень идёт». Журнал:
  `web_ios (safari, ios)`, 33 с игры, скорость 99–100 %, без остановок и замираний,
  самый долгий кадр телефона 32 мс. Прежний NO SUCH ROOM не повторился; его причина
  по-прежнему не установлена.
- **Комната с iPhone и «Поделиться» — прошли.** iPhone создал 3VXVPQ
  (`web_ios (safari, ios)`), ссылка ушла через системное окно, и пользователь открыл её
  в своём Chrome на Mac: `web (chrome, macos)` вошёл через 28 с, обе стороны начали
  stage 1. Пользователь: «работает». Перед входом Chrome на Mac четыре раза обрывал
  TLS с `unknown certificate` — то же было при первой попытке 8PXU3U; вход это не
  остановило, причина не разбиралась.
- **«На экран Домой» — запуск прошёл, вход по коду оттуда — нет.** Пользователь:
  «работает, адресной строки нет». Компьютер ждал в TGAK6B (комната жила всё время,
  `/health` — 1 комната, экран WAITING FOR PLAYER), но в неё никто не вошёл. Вместо
  этого журнал: `18:05:36 refused (join): no room with that code` и такой же в
  `19:29:21`. Сервер ищет код точным совпадением (`Hub.Find`), а клиент отправляет
  только шесть очищенных знаков (`Net.clean_code`), то есть ушёл какой-то другой код из
  шести знаков. Какой — журнал не пишет. Это тот же NO SUCH ROOM, что в октябре.
  Третья попытка из запуска со значка вошла: `19:32:09 … player 2 joined …
  web_ios (safari, ios)`, оба начали stage 1, скорость 100 %, без остановок;
  пользователь: «подключился, работает». Снимков неудачных попыток нет. Предложение
  писать в журнал код отказа (только в форме настоящего кода, иначе слово-заглушка)
  сделано пользователю, ответа пока нет — не реализовано.

### С чего продолжить

Пункты 1–4 прежнего списка (ссылка, ручной ввод, «Поделиться», домашний экран)
выполнены 2026-11-21 — см. «Живые проверки 2026-11-21» выше. Пункт 5 сделан в тот же
день: `RotateHint` удалён вместе со строкой в `test_touch_controls.gd`, дописаны
`AGENTS.md` (документы, карта кода, грабли), мобильный раздел `README.md` и «Что
проверено» в спеке.

Осталось:

1. Решение пользователя: писать ли в журнал сервера код отказанного входа, чтобы
   разобрать NO SUCH ROOM. Не делать без ответа.
2. Итоговое ревью ветки, полный тест, отчёт пользователю. MR/push не разрешены.

## Состояние на 2026-10-03 — для того, кто продолжит

Работа идёт в ветке `feat/mobile-web-game` (worktree
`~/.superconductor/worktrees/base13/sc-paired-niobium-98d8`), от master `a72d740`. Всё
закоммичено, `./tools/test.sh` зелёный: 628 тестов GUT, Go, проверки изоляции и атласов.

### Где мы

- Задачи 1–9 сделаны. Задача 10 (живая проверка на iPhone и документы) в процессе.
- Первый круг живой проверки: пункты 1 (одиночная игра, звук) и 6 (компьютер)
  прошли. Горизонтальная раскладка оказалась мелкой, стик неудобным. По решению
  пользователя раскладка стала **вертикальной** — это отход от спеки, которая говорила
  «только горизонтально». Горизонталь осталась и работает при повороте.
- Пользователь посмотрел `83a991f` на iPhone и прислал снимки. После локальных макетов
  согласован **вариант А**: показатели под увеличенным полем только на телефоне,
  отдельная консольная панель, красная FIRE и вытянутая START ровно по центру. Подпись
  START близко к кнопке, в уровне не меняется на PAUSE. Все поверхности анимируют
  нажатие, удержание и отпускание. Реализация готова, полный прогон зелёный: 628 тестов
  GUT, Go, изоляция и ресурсы. Браузерная проверка касаний, поворота и короткого экрана
  прошла. Пользователь проверил на iPhone и прислал снимки меню и паузы: попросил
  зазор под START, более крупный текст и отклик стрелок без свайпа. Исправлено; повторная
  живая проверка прошла: пользователь одобрил вид после исправлений.
- По просьбе пользователя подготовлена отдельная локальная проверка отдачи:
  `tools/haptics-check.html`, на сервере телефона `/haptics-check.html`. Сравниваются
  прямое касание системного `input switch`, такой же переключатель поверх FIRE,
  программный вызов и `navigator.vibrate(30)`. Библиотеки не подключались. Браузерные
  тесты проходят. Пользователь проверил Safari и Chrome на iPhone: в обоих работают
  пункты 1 и 2, толчок только при отпускании короткого тапа; после удержания его нет.
  Опыт завершён. 2026-10-04 пользователь решил пока оставить управление без
  вибрации, с анимацией кнопок.
- 2026-10-05 после проверки QUICK GAME пользователь подтвердил сетевую игру двух
  пользователей на телефоне и компьютере. Комната по коду, «Поделиться» / `?room=` и
  домашний экран ещё не подтверждены.
- Пользователь заметил отсутствие выстрелов при частых тапах FIRE; анимация кнопки
  срабатывает. Диагностика не выявила потери касаний: 200 коротких тапов (в том числе
  со стрелкой) дошли до сетевого ввода, 60 снятий удержания — до локального. В неизменённой
  симуляции два принятых тапа подряд дают один выстрел, следующий после исчезновения
  пули — новый: обычному танку разрешена одна пуля в полёте. Пользователь подтвердил
  повторной проверкой на телефоне: FIRE работает; исправление ввода не требуется.

### Что осталось

1. Вид и исправления второго круга одобрены. Отдельная проверка отдачи завершена:
   Safari и Chrome дают толчок только при отпускании короткого тапа, после удержания
   его нет. Решение пользователя от 2026-10-04 — оставить анимацию кнопок без вибрации.
2. Десктопная раскладка согласована: показатели справа и общая серая рамка остаются.
3. Повторить вход в комнату по коду после исправления поля, затем «Поделиться» /
   `?room=` и домашний экран (остаток пунктов 3–5 задачи 10). FIRE проверена и работает.
   При первом входе пользователь не увидел клавиатуру: нажимал на нарисованный код,
   настоящее HTML-поле было у верха страницы. Теперь поле стоит под ROOM CODE, рисунок
   убран; TAP HERE и TAP TO TYPE показывают, куда нажать. TAP HERE исчезает при фокусе
   и возвращается после выхода из пустого поля. Пользователь получил NO SUCH ROOM;
   причина пока не установлена. Сервер держал комнату, контрольный вход через пустое
   мобильное поле во втором Chrome прошёл; оба браузера сыграли уровень. Создана новая
   комната для повторной проверки на телефоне, сначала по ссылке с заполненным кодом.
4. Уборка: `RotateHint` (`game/ui/rotate_hint.gd`) больше нигде не показывается — в
   вертикали игра теперь играет. Удалить класс и его строку в
   `test_touch_controls.gd` (`test_the_labels_can_be_drawn`).
5. Документы, шаг 3 задачи 10:
   - спека: вертикаль, вариант А, TLS, кэш и автообновление уже обновлены; раздел
     «Что проверено» дописать итогами новой живой проверки;
   - `AGENTS.md`: документы, карта кода, «грабли» (ниже);
   - `README.md`: игра с телефона в браузере.
6. Итоговое ревью всей ветки, затем отчёт пользователю. MR — только по его отдельному
   подтверждению, после зелёного `./tools/test.sh` и показанного отчёта.

### Решения, принятые по ходу (кроме плана)

- **Вертикальная раскладка** (решение пользователя). Поле сверху на всю ширину; под ним
  в одном ряду внизу, как на геймпаде NES: крест слева, START посередине, FIRE справа.
  Раскладка в `StageLayout` (`picture_at`, `stick_zone`, `button_zone`, `thumb_row`),
  размещение в `TouchControls.place`.
- **Растяжение на телефоне**: `content_scale_aspect = EXPAND`, `content_scale_stretch =
  FRACTIONAL`, `content_scale_mode = CANVAS_ITEMS` (`App._fit_touch`). На компьютере всё
  как было (`viewport`, целое увеличение).
- **Стик**: `VirtualJoystick` в режиме `FIXED` с центром на рисунке креста. По результатам
  живой проверки обычное нажатие на стрелку сразу включает направление; перетаскивание
  тоже работает. Быстрый тап сохраняется между кадрами, отмена не создаёт новое нажатие.
- **Вариант А** (согласован 2026-10-03): на телефоне поле 240×240 в рамке 256×288,
  показатели одной строкой под ним; короткий экран уменьшает рамку с сохранением
  пропорций. `StageLayout.game_rect` и `Game.layout_touch`; десктоп не вызывает их.
  Панель в `TouchControlArt`: светлый крест, красная FIRE, вытянутая START с небольшим
  зазором до подписи. Текст меню, паузы и сообщений над полем на телефоне в масштабе 2.
  Кнопки на одной высоте, START ровно по центру. Tween двигает поверхность,
  зона касания остаётся на месте. При blur/hidden отпускаются и действия, и пальцы
  движка. START всегда подписан START, включая уровень.
- **Серая рамка вокруг поля**, как на NES (`game.gd`, `_draw`, цвет `HudPanel.BACKGROUND`).
- **Кэш** (решение пользователя): сервер ставит `Cache-Control: no-cache` на **все** файлы
  игры (`alwaysRevalidate` в `server/main.go`); неизменённый файл стоит 304.
- **Автообновление**: на заставке и в меню игра спрашивает service worker о новой версии
  и перезапускается в неё (`App._take_update`, `JavaScriptBridge.pwa_update`). Без этого
  Godot держит старую версию, пока не закрыты все окна игры.
- `CACHE_VERSION` в service worker Godot разный у каждой сборки, поэтому правка
  `tools/build.sh` из задачи 9 не понадобилась.
- `?selftest` пишет результат в две строки: в одну `RESIM` обрезался на любом экране.
- Плановое поле ввода кода (`CodeField.OPEN`) не работало: `%` в CSS ломал форматирование
  GDScript. Экранировано `%%`, есть тест `test_code_field.gd`.

### Грабли для AGENTS.md

- mkcert при заданном `JAVA_HOME` падает на `keytool`, не выписав сертификат:
  `tools/phone.sh` запускает его через `env -u JAVA_HOME`.
- Safari открывает адрес с портом без схемы по `http`, и сервер TLS отвечает текстом —
  Safari скачивает его как `document.txt`. Набирать `https://` целиком.
- Godot service worker отдаёт игру из кэша, а новую версию держит в ожидании, пока не
  закрыты все окна. Перезагрузка страницы показывает старую сборку. Лечится
  `pwa_update` (сделано); в эмуляции — `Network.setBypassServiceWorker`.
- Сервер отдавал `index.pck`/`index.wasm` без `Cache-Control`, и браузер держал их по
  своей оценке — десятую долю возраста файла (Chrome на iPhone показал старую сборку).
- Переключать `content_scale_aspect` в обработчике `size_changed` нельзя: на iPhone
  вьюпорт остался посчитан под ушедший размер окна и занял три четверти ширины. `EXPAND`
  делает это сам.
- Дробное растяжение в режиме `viewport` даёт пиксели разной ширины и ступенчатые круги;
  на телефоне нужен `canvas_items`.
- Чёрная рамка вокруг чёрного поля не видна: танк «упирается в ничто».
- В headless `Input.parse_input_event` не проверяет GUI стика как реальный экран.
  Тесты маршрутизируют касания через `SubViewport.push_input` с нужным размером, включая
  нажатие и отпускание между кадрами. Проверять также глазами: в
  `agent-browser` команда `set device` не включает касания — нужен свой CDP-сеанс с
  `Emulation.setTouchEmulationEnabled` (эмуляция живёт, пока сеанс открыт) и
  `Input.dispatchTouchEvent`.

### Как проверять

- `just phone` (или `just phone --build`) — сборка на телефон по HTTPS, адрес мака в
  Wi-Fi, порт 8443. Корневой сертификат mkcert на iPhone уже доверенный.
- После новой сборки телефон подхватывает её сам на заставке или в меню.

> **Для исполнителя:** работать по задачам сверху вниз, каждая — полный цикл TDD и
> коммит. Шаги отмечены `- [ ]`. Можно использовать superpowers:executing-plans.

**Цель:** в веб-версию BASE 13 можно играть с телефона, держа его горизонтально: стик и
кнопки на экране, меню как на консоли, вход в комнату по коду и по ссылке, установка на
домашний экран.

**Архитектура:** касания — ещё один источник тех же пяти кнопок. Готовые узлы Godot
(`VirtualJoystick`, `TouchScreenButton`) ловят пальцы, слой `TouchControls` превращает то,
что они сообщают, в действия `touch_*` — единственное, что читает остальная игра. Экраны
разбирают ввод через общий классификатор `UiInput`. На сенсорном устройстве вьюпорт
сохраняет высоту 240 и занимает ширину окна; картинка 256×240 стоит по центру, кнопки — в
полосах по бокам. Ядро, сеть и сервер комнат не меняются, кроме заголовков кэша.

**Стек:** Godot 4.7.2, GDScript, GUT; Go для сервера; mkcert для проверки на телефоне.

**Спецификация:** `docs/specs/2026-09-28-mobile-web-design.md` — прочитать целиком до начала.

## Как выполнять

Работа идёт **в отдельном worktree, созданном через `sc`, с передачей управления в новую
вкладку Claude Code**. Сессия, написавшая план, только запускает её и отчитывается.

1. Планирующая сессия запускает `sc worktree create --from-file <файл с заданием>
   --provider claude` (перед этим — `sc instructions worktree`; целевая ветка — по
   `sc worktree status --json`). Команда создаёт worktree с новой веткой, открывает
   вкладку и отдаёт ей задание первым сообщением.
2. Новая сессия делает все задачи **в своём worktree** и другого worktree не создаёт.
   Коммит после каждой задачи, сообщения по-английски (`feat:`, `test:`, `docs:`,
   `chore:`), **без строк Co-Authored-By**.
3. Ничего наружу (MR/PR, релиз, сообщения) без отдельного подтверждения пользователя.
   MR — только после зелёного `./tools/test.sh` и показанного отчёта о проверке.
4. **Стоп-точки — там, где нужен человек с iPhone в руках:**
   - Задача 1: после замеров на телефоне показать пользователю числа и ждать решения.
   - Задача 10: живая проверка — выдать адрес и список проверок, ждать результатов.

## Что меняется, простыми словами

Сейчас на телефоне игра открывается, но не слушается: касания не делают ничего. После этой
работы телефон держат горизонтально, слева — крестовина под большой палец, справа —
ОГОНЬ и START. Ими же управляются меню: вверх/вниз выбирают, ОГОНЬ — «да», START — назад
или пауза. Если повернуть телефон вертикально, игра просит повернуть обратно.

Чтобы сыграть с другом, можно нажать «Поделиться» на экране созданной комнаты и отправить
ссылку в мессенджер: друг открывает её и сразу попадает на экран входа с вписанным кодом.
Код можно и набрать — появляется обычная клавиатура телефона. Игру можно добавить на
домашний экран, тогда она открывается без адресной строки.

На компьютере всё остаётся как было.

## Общие ограничения

- Правила из `AGENTS.md` «Hard rules» в силе. `game/core/` не трогаем вообще:
  `Golden.EXPECTED` и `test_regression.gd` не должны сдвинуться.
- Базовое разрешение остаётся 256×240; масштаб — только целый.
- Шрифт знает только цифры, заглавные латинские, точку и двоеточие — каждую новую
  надпись проверять тестом через `TextPainter.glyph_index` и `width_of`.
- Сенсорное устройство: нативные Android/iOS — всегда; браузер — когда
  `matchMedia('(pointer: coarse)')` истинно. Ноутбук с сенсорным экраном — не сенсорное.
- Только горизонтальная ориентация; в портрете — надпись `ROTATE PHONE`.
- Код из ссылки проходит то же правило, что набранный: заглавные, только символы шрифта,
  не длиннее шести.
- В комнату по ссылке не входим сами — нужно нажатие ОГОНЬ.
- `LAN HOST` / `LAN JOIN` скрыты во всей веб-версии.
- Сервер: слова `tank|bullet|projectile|level|eagle|base13` запрещены в не-тестовых файлах
  `server/` (`check_server_neutral.sh` смотрит и в комментарии).
- В `tools/*.sh` нет ассоциативных массивов (bash 3.2 на macOS).
- Лямбда GDScript захватывает локальные переменные копией — копить результат в массиве.
- JS возвращает строки, не bool (см. `App._wants_selftest`).

## Отступление от спеки

Спека говорит «Caddy с сертификатом mkcert». Caddy не нужен: сервер комнат сам умеет TLS
(`-tls-cert`, `-tls-key`, `server/main.go`). `just phone` поднимает его на адресе мака с
сертификатом mkcert — одна зависимость вместо двух, тот же результат. В спеке поправить
в задаче 10.

Спека допускает встроенную клавиатуру Godot вместо своего поля. План выбирает своё поле
сразу: движок разбирает касание кадром позже, а iOS открывает клавиатуру только для поля,
получившего фокус в самом касании, — ровно то, чего встроенная не может.

## Команды

```bash
./tools/test.sh                          # всё: изоляция, атласы, Go, GUT
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --headless --path game -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests -ginclude_subdirs -gselect=test_touch -gexit   # один файл
(cd server && go test -count=1 -run TestPwa ./...)                  # один Go-тест
./tools/build.sh Web                     # веб-сборка в build/web
just phone                               # сборка на телефон по HTTPS (задача 1)
```

## Review Focus

Что спека подразумевает, но легко сломать и не заметить:

1. **Палец у диагонали** — танк не должен дёргаться между двумя направлениями кадр за
   кадром. Тест: `test_near_diagonal_keeps_the_direction` (задача 2).
2. **Тап огня короче шага** — тап между двумя снятиями тика не теряется, в том числе пока
   тик стоит за партнёром. Тест: `test_a_fire_tap_is_latched_for_player_one` (задача 2).
3. **Мусор в `?room=`** — `%0A`, строчные, длинная строка, чужие символы не проходят мимо
   правила кода. Тест: `test_a_code_in_the_link_is_cleaned` (задача 8).
4. **Клавиатура телефона при открытом поле** — буквы не должны попасть в код дважды (из
   поля и из key-событий движка). Тест: `test_keys_are_ignored_while_the_field_is_open`
   (задача 8).
5. **Обновление после релиза** — service worker не должен держать старый `index.pck`.
   Проверка: разные `CACHE_VERSION` у двух сборок + Go-тест на заголовки (задача 9).

## Карта файлов

Создаются:

| Файл | Что делает |
|------|-----------|
| `tools/phone.sh` | Сборка на телефон по HTTPS: mkcert + сервер комнат с TLS на адресе мака |
| `game/platform/touch.gd` | `Touch`: наклон стика → одно направление; биты из `touch_*` |
| `game/platform/touch_device.gd` | `TouchDevice`: сенсорное ли устройство |
| `game/ui/ui_input.gd` | `UiInput`: событие → UP/DOWN/CONFIRM/BACK/START |
| `game/ui/stage_layout.gd` | `StageLayout`: смещение картинки, портрет ли окно |
| `game/ui/touch_controls.gd` | `TouchControls`: стик и две кнопки, рисунок, действия `touch_*` |
| `game/ui/rotate_hint.gd` | `RotateHint`: `ROTATE PHONE` поверх всего в портрете |
| `game/platform/code_field.gd` | `CodeField`: HTML-поле для кода поверх канваса |
| `game/platform/room_link.gd` | `RoomLink`: код в адресе страницы, ссылка, «Поделиться» |
| тесты | `game/tests/platform/test_touch.gd`, `test_touch_device.gd`, `test_room_link.gd`, `game/tests/ui/test_ui_input.gd`, `test_stage_layout.gd`, `test_touch_controls.gd`, `test_pause_choice.gd` |

Меняются: `justfile`, `game/project.godot`, `game/platform/local_input.gd`,
`game/net/net_input.gd`, `game/platform/press_latch.gd`, `game/platform/relay_config.gd`,
`game/ui/skip_input.gd`, `game/ui/menu.gd`, `game/ui/pause.gd`, `game/ui/game.gd`,
`game/ui/net.gd`, `game/ui/app.gd`, `tools/gen_sprites.py`, `game/export_presets.cfg`,
`server/main.go`, `server/server_test.go`, тесты `test_menu_choice.gd`,
`test_net_screen.gd`, `test_skip_input.gd`, `test_relay_config.gd`; документы.

---

### Задача 1: `just phone` и разведка на iPhone (стоп-точка)

Узнаём до всех вложений: запускается ли игра на iPhone, хватает ли ему скорости на откат,
включается ли звук.

**Files:**
- Create: `tools/phone.sh`
- Modify: `justfile`

- [ ] **Шаг 1: скрипт**

`tools/phone.sh`:

```bash
#!/usr/bin/env bash
# The web build on a phone on the same Wi-Fi. A browser starts the game only from
# a secure origin — https, or localhost, which a phone is not — so the room server
# serves the build itself over TLS, with a certificate mkcert makes for this Mac's
# address. Nothing leaves the local network.
#
#   just phone            # serve what is in build/web, building it if missing
#   just phone --build    # build the web version again first
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8443}"

for tool in mkcert go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is missing: brew install $tool"
    exit 1
  fi
done

ip="${PHONE_IP:-}"
if [ -z "$ip" ]; then
  ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
fi
if [ -z "$ip" ]; then
  echo "no Wi-Fi address found: set PHONE_IP=192.168.x.y"
  exit 1
fi

if [ "${1:-}" = "--build" ] || [ ! -f build/web/index.html ]; then
  ./tools/build.sh Web
fi

mkdir -p .build/phone
mkcert -cert-file .build/phone/cert.pem -key-file .build/phone/key.pem \
  "$ip" localhost 127.0.0.1 >/dev/null 2>&1
(cd server && GOTOOLCHAIN=local go build -mod=readonly -o ../.build/relay .)

echo
echo "On the phone:  https://$ip:$PORT/"
echo "Speed check:   https://$ip:$PORT/?selftest"
echo
echo "First time only, so the phone trusts the certificate:"
echo "  1. AirDrop $(mkcert -CAROOT)/rootCA.pem to the iPhone"
echo "  2. Settings > General > VPN & Device Management: install the profile"
echo "  3. Settings > General > About > Certificate Trust Settings: turn it on"
echo
exec .build/relay -addr "$PORT" -static build/web \
  -tls-cert .build/phone/cert.pem -tls-key .build/phone/key.pem
```

```bash
chmod +x tools/phone.sh
```

- [ ] **Шаг 2: рецепт в `justfile`** (после `serve`)

```make
# The web build on a phone on the same Wi-Fi, over https with a mkcert certificate
phone *args:
    ./tools/phone.sh {{args}}
```

- [ ] **Шаг 3: проверить на маке**

```bash
brew install mkcert   # если нет
just phone --build &
sleep 5
curl -sk https://127.0.0.1:8443/ | grep -c "<canvas"   # ожидается 1
curl -sk https://127.0.0.1:8443/health                 # ожидается {"ok":true,...}
kill %1
```

Если `-addr` не принимает голый порт — посмотреть `server/config.go` `settings` и передать
то, что он принимает (`:8443`).

- [ ] **Шаг 4: коммит**

```bash
git add tools/phone.sh justfile
git commit -m "chore: just phone serves the web build to a phone over https"
```

- [ ] **Шаг 5: разведка с пользователем — СТОП**

Запустить `just phone`, дать пользователю адрес и попросить на iPhone в Safari:

1. открыть `https://<ip>:8443/?selftest` и прислать строку `SELFTEST OK … TICK … SAVE …
   RESIM …` с экрана (или скриншот);
2. открыть `https://<ip>:8443/`: дошла ли игра до меню, есть ли звук на заставке после
   первого касания экрана;
3. прислать модель iPhone и версию iOS.

Порог: `RESIM` (восстановление и двенадцать тиков заново) **до 8000 мкс** — половина кадра
при 60 Гц. Показать пользователю числа рядом с десктопным браузером (0,4 мс на тик,
`AGENTS.md`) и ждать решения. При `RESIM` выше порога — не продолжать без него.

Записать числа в спеку, раздел «Что проверено» (создать его в конце спеки), коммит
`docs: what an iPhone makes of the current build`.

---

### Задача 2: касания как источник пяти кнопок

**Files:**
- Create: `game/platform/touch.gd`, `game/tests/platform/test_touch.gd`
- Modify: `game/project.godot` (секция `[input]`), `game/platform/local_input.gd`,
  `game/net/net_input.gd:174-180`, `game/platform/press_latch.gd:30-46`

**Interfaces:**
- Produces: `Touch.compose(stick: Vector2, previous: int) -> int` (0 или один из
  `Types.IN_UP/IN_DOWN/IN_LEFT/IN_RIGHT`); `Touch.bits() -> int`;
  `Touch.pressed_bits(event: InputEvent) -> int`; `Touch.ACTIONS: Dictionary`
  (`StringName → бит`); действия `touch_up`, `touch_down`, `touch_left`, `touch_right`,
  `touch_fire`, `touch_start`, `touch_stick_left`, `touch_stick_right`,
  `touch_stick_up`, `touch_stick_down`.

- [ ] **Шаг 1: действия в `project.godot`**

Добавить секцию `[input]` (после `[display]`), без событий — их нажимает только
`TouchControls`:

```ini
[input]

touch_up={
"deadzone": 0.2,
"events": []
}
touch_down={
"deadzone": 0.2,
"events": []
}
touch_left={
"deadzone": 0.2,
"events": []
}
touch_right={
"deadzone": 0.2,
"events": []
}
touch_fire={
"deadzone": 0.2,
"events": []
}
touch_start={
"deadzone": 0.2,
"events": []
}
touch_stick_left={
"deadzone": 0.0,
"events": []
}
touch_stick_right={
"deadzone": 0.0,
"events": []
}
touch_stick_up={
"deadzone": 0.0,
"events": []
}
touch_stick_down={
"deadzone": 0.0,
"events": []
}
```

- [ ] **Шаг 2: падающие тесты** — `game/tests/platform/test_touch.gd`

```gdscript
extends GutTest

## The screen's stick and buttons as the same five bits: one direction at a time,
## steady near the diagonal, and a tap that is not lost between two ticks.

func after_each() -> void:
	for action in Touch.ACTIONS:
		Input.action_release(action)
	PressLatch.clear()

func _action(name: StringName, pressed := true) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = pressed
	return e

func test_a_resting_thumb_is_no_move() -> void:
	assert_eq(Touch.compose(Vector2(0.2, -0.1), 0), 0)
	assert_eq(Touch.compose(Vector2.ZERO, Types.IN_UP), 0, "letting go stops the tank")

func test_each_way() -> void:
	assert_eq(Touch.compose(Vector2(0, -1), 0), Types.IN_UP)
	assert_eq(Touch.compose(Vector2(0, 1), 0), Types.IN_DOWN)
	assert_eq(Touch.compose(Vector2(-1, 0), 0), Types.IN_LEFT)
	assert_eq(Touch.compose(Vector2(1, 0), 0), Types.IN_RIGHT)

func test_one_direction_at_a_time() -> void:
	# Two bits would leave the choice to the core's priority rule, which the
	# thumb cannot see.
	assert_eq(Touch.compose(Vector2(0.7, -0.6), 0), Types.IN_RIGHT)
	assert_eq(Touch.compose(Vector2(0.6, -0.7), 0), Types.IN_UP)

func test_near_diagonal_keeps_the_direction() -> void:
	# The same thumb, a hair past the diagonal: whichever way the tank was going,
	# it keeps going. Without this it flips frame by frame.
	assert_eq(Touch.compose(Vector2(0.62, -0.72), Types.IN_RIGHT), Types.IN_RIGHT)
	assert_eq(Touch.compose(Vector2(0.72, -0.62), Types.IN_UP), Types.IN_UP)

func test_a_clear_lead_turns() -> void:
	assert_eq(Touch.compose(Vector2(0.4, -0.9), Types.IN_RIGHT), Types.IN_UP)
	assert_eq(Touch.compose(Vector2(-0.9, -0.4), Types.IN_UP), Types.IN_LEFT)

func test_bits_read_the_actions() -> void:
	Input.action_press(&"touch_up")
	Input.action_press(&"touch_fire")
	assert_eq(Touch.bits(), Types.IN_UP | Types.IN_FIRE)

func test_start_is_not_a_game_bit() -> void:
	Input.action_press(&"touch_start")
	assert_eq(Touch.bits(), 0, "START pauses; it must not reach the simulation")

func test_a_fire_tap_is_latched_for_player_one() -> void:
	PressLatch.note(_action(&"touch_fire"))
	PressLatch.note(_action(&"touch_fire", false))
	assert_eq(PressLatch.take(0), Types.IN_FIRE, "a tap between two ticks was lost")
	assert_eq(PressLatch.take(1), 0, "the screen belongs to player one")

func test_a_release_is_not_a_press() -> void:
	assert_eq(Touch.pressed_bits(_action(&"touch_fire", false)), 0)

func test_a_closed_latch_notes_no_tap() -> void:
	PressLatch.note(_action(&"touch_fire"), false)
	assert_eq(PressLatch.take(0), 0)

func test_local_input_hears_the_screen() -> void:
	Input.action_press(&"touch_left")
	var bits: Array[int] = LocalInput.new().inputs_for(0)
	assert_eq(bits[0] & Types.IN_LEFT, Types.IN_LEFT)
	assert_eq(bits[1], 0)
```

- [ ] **Шаг 3: запустить — падает** (`Touch` не существует)

```bash
$GODOT --headless --path game -s addons/gut/gut_cmdln.gd -gdir=res://tests \
  -ginclude_subdirs -gselect=test_touch -gexit
```

- [ ] **Шаг 4: `game/platform/touch.gd`**

```gdscript
class_name Touch

## The same five bits from the screen. `TouchControls` turns the stick and the
## buttons into the actions below, and this reads them the way `Keyboard` reads
## keys. On a machine nobody touches, nothing presses them and the OR is zero.

const ACTIONS := {
	&"touch_up": Types.IN_UP, &"touch_down": Types.IN_DOWN,
	&"touch_left": Types.IN_LEFT, &"touch_right": Types.IN_RIGHT,
	&"touch_fire": Types.IN_FIRE,
}
## Below this the stick is at rest: a thumb laid on it is not yet a move.
const DEADZONE := 0.35
## How far the other axis must pull ahead before the direction changes. Without it a
## thumb resting near the diagonal flips the tank between two ways every frame.
const HOLD := 0.2

## One direction bit or zero. The tank drives four ways; two bits at once would leave
## the choice to the core's priority rule, which a thumb cannot see.
static func compose(stick: Vector2, previous: int) -> int:
	if stick.length() < DEADZONE:
		return 0
	var across := absf(stick.x)
	var along := absf(stick.y)
	var horizontal := across > along
	if previous == Types.IN_LEFT or previous == Types.IN_RIGHT:
		horizontal = across + HOLD > along
	elif previous == Types.IN_UP or previous == Types.IN_DOWN:
		horizontal = across > along + HOLD
	if horizontal:
		return Types.IN_RIGHT if stick.x > 0.0 else Types.IN_LEFT
	return Types.IN_DOWN if stick.y > 0.0 else Types.IN_UP

static func bits() -> int:
	var mask := 0
	for action in ACTIONS:
		if Input.is_action_pressed(action):
			mask |= ACTIONS[action]
	return mask

## The bit a `touch_*` action going down gives, for `PressLatch`.
static func pressed_bits(event: InputEvent) -> int:
	var action := event as InputEventAction
	if action == null or not action.pressed:
		return 0
	return ACTIONS.get(action.action, 0)
```

- [ ] **Шаг 5: подключить**

`game/platform/press_latch.gd`, в `note` сразу после цикла по `Keyboard.pressed_bits`:

```gdscript
	# The screen is player one's: a phone has one pair of thumbs on it.
	_seen[0] |= Touch.pressed_bits(event)
```

`game/platform/local_input.gd`:

```gdscript
func inputs_for(_tick: int) -> Array[int]:
	return [
		Keyboard.bits(0) | Gamepad.bits(0) | Touch.bits() | PressLatch.take(0),
		Keyboard.bits(1) | Gamepad.bits(1) | PressLatch.take(1),
	] as Array[int]
```

В комментарий класса добавить: «The screen's controls count as player one's.»

`game/net/net_input.gd`, `_read_bits`:

```gdscript
		held = Keyboard.bits(0) | Gamepad.bits(0) | Touch.bits()
```

- [ ] **Шаг 6: тесты зелёные, весь прогон зелёный**

```bash
./tools/test.sh
```

- [ ] **Шаг 7: коммит**

```bash
git add game/project.godot game/platform/touch.gd game/platform/local_input.gd \
  game/net/net_input.gd game/platform/press_latch.gd game/tests/platform/test_touch.gd
git commit -m "feat: the screen's stick and buttons as the same five bits"
```

---

### Задача 3: сенсорное ли устройство, классификатор ввода, «любая кнопка»

**Files:**
- Create: `game/platform/touch_device.gd`, `game/ui/ui_input.gd`,
  `game/tests/platform/test_touch_device.gd`, `game/tests/ui/test_ui_input.gd`
- Modify: `game/ui/skip_input.gd`, `game/tests/ui/test_skip_input.gd`

**Interfaces:**
- Produces: `TouchDevice.present() -> bool`, `TouchDevice.decide(os_name: String,
  pointer: String) -> bool`, `TouchDevice.force(value: int) -> void` (−1 — спросить
  машину снова, 0 — нет, 1 — да); `UiInput.Act { NONE, UP, DOWN, CONFIRM, BACK, START }`,
  `UiInput.of(event: InputEvent) -> int`.

- [ ] **Шаг 1: падающие тесты**

`game/tests/platform/test_touch_device.gd`:

```gdscript
extends GutTest

## Who plays by touch. A phone's browser says so through its pointer; a laptop with a
## touch screen has a mouse first and keeps the keyboard's screens.

func after_each() -> void:
	TouchDevice.force(-1)

func test_a_phone_browser_is_touch() -> void:
	assert_true(TouchDevice.decide("Web", "coarse"))

func test_a_desktop_browser_is_not() -> void:
	assert_false(TouchDevice.decide("Web", "fine"))
	assert_false(TouchDevice.decide("Web", ""), "an unanswered question is not a finger")

func test_native_phones_are_touch() -> void:
	assert_true(TouchDevice.decide("Android", ""))
	assert_true(TouchDevice.decide("iOS", ""))

func test_a_desktop_is_not() -> void:
	assert_false(TouchDevice.decide("macOS", ""))
	assert_false(TouchDevice.decide("Windows", ""))

func test_the_test_machine_is_not_touch() -> void:
	# Headless: no browser, no phone. Every other test relies on this.
	assert_false(TouchDevice.present())

func test_force_overrides_and_resets() -> void:
	TouchDevice.force(1)
	assert_true(TouchDevice.present())
	TouchDevice.force(-1)
	assert_false(TouchDevice.present())
```

`game/tests/ui/test_ui_input.gd`:

```gdscript
extends GutTest

## What a press means to a menu, from each device. The network screen once knew
## only the keyboard, and a player with a pad or a phone could not leave it.

func _key(physical: int, pressed := true, echo := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical
	e.pressed = pressed
	e.echo = echo
	return e

func _pad(button: int, pressed := true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = pressed
	return e

func _action(name: StringName, pressed := true) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = pressed
	return e

func test_keys() -> void:
	assert_eq(UiInput.of(_key(KEY_UP)), UiInput.Act.UP)
	assert_eq(UiInput.of(_key(KEY_W)), UiInput.Act.UP)
	assert_eq(UiInput.of(_key(KEY_DOWN)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_key(KEY_S)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_key(KEY_ENTER)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_key(KEY_SPACE)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_key(KEY_ESCAPE)), UiInput.Act.BACK)
	assert_eq(UiInput.of(_key(KEY_F)), UiInput.Act.NONE)

func test_a_release_or_repeat_is_nothing() -> void:
	assert_eq(UiInput.of(_key(KEY_UP, false)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_key(KEY_UP, true, true)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_A, false)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_action(&"touch_fire", false)), UiInput.Act.NONE)

func test_pad() -> void:
	assert_eq(UiInput.of(_pad(JOY_BUTTON_DPAD_UP)), UiInput.Act.UP)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_DPAD_DOWN)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_A)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_START)), UiInput.Act.START)

func test_screen() -> void:
	assert_eq(UiInput.of(_action(&"touch_up")), UiInput.Act.UP)
	assert_eq(UiInput.of(_action(&"touch_down")), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_action(&"touch_fire")), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_action(&"touch_start")), UiInput.Act.START)
	assert_eq(UiInput.of(_action(&"touch_left")), UiInput.Act.NONE)

func test_anything_else_is_nothing() -> void:
	assert_eq(UiInput.of(InputEventMouseMotion.new()), UiInput.Act.NONE)
	assert_eq(UiInput.of(InputEventScreenTouch.new()), UiInput.Act.NONE)
```

В `game/tests/ui/test_skip_input.gd` дописать:

```gdscript
func _action(name: StringName, pressed := true) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = pressed
	return e

func test_screen_buttons_skip() -> void:
	# A phone has no keys: without this the tally waits out its timer.
	assert_true(SkipInput.is_skip(_action(&"touch_fire")))
	assert_true(SkipInput.is_skip(_action(&"touch_start")))
	assert_false(SkipInput.is_skip(_action(&"touch_fire", false)))

func test_the_stick_does_not_skip() -> void:
	# A thumb resting on the stick through the tally must not sweep it away.
	assert_false(SkipInput.is_skip(_action(&"touch_up")))
```

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/platform/touch_device.gd`**

```gdscript
class_name TouchDevice

## Whether this machine is played by touch: the controls go on screen and the menus
## drop what a phone cannot do. Asked once — a machine does not grow a touch screen
## mid-game.

static var _known := -1   ## -1 not asked yet, 0 no, 1 yes

static func present() -> bool:
	if _known < 0:
		_known = 1 if decide(OS.get_name(), _pointer()) else 0
	return _known == 1

## `pointer` is what a browser says of its main pointer: "coarse" is a finger. The
## user agent cannot tell: an iPad asking for the desktop site calls itself a Mac. A
## laptop with a touch screen answers "fine" — its mouse comes first, and so do the
## keyboard's screens.
static func decide(os_name: String, pointer: String) -> bool:
	if os_name == "Android" or os_name == "iOS":
		return true
	return pointer == "coarse"

## For tests: what `present` answers from now on; -1 asks the machine again.
static func force(value: int) -> void:
	_known = value

static func _pointer() -> String:
	if not OS.has_feature("web"):
		return ""
	# A string rather than a boolean: see App._wants_selftest.
	var answer = JavaScriptBridge.eval(
		"window.matchMedia('(pointer: coarse)').matches ? 'coarse' : 'fine'", true)
	return answer if typeof(answer) == TYPE_STRING else ""
```

- [ ] **Шаг 4: `game/ui/ui_input.gd`**

```gdscript
class_name UiInput

## What a press means to a menu, whichever device made it. The screens used to take
## keys apart each on its own, and the network screen knew only the keyboard.
##
## BACK and START are kept apart: Esc does nothing on the title menu, while START
## there begins the game, as it did on the console.

enum Act { NONE, UP, DOWN, CONFIRM, BACK, START }

static func of(event: InputEvent) -> int:
	var key := event as InputEventKey
	if key != null:
		if not key.pressed or key.echo:
			return Act.NONE
		match key.physical_keycode:
			KEY_UP, KEY_W:
				return Act.UP
			KEY_DOWN, KEY_S:
				return Act.DOWN
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				return Act.CONFIRM
			KEY_ESCAPE:
				return Act.BACK
		return Act.NONE
	var button := event as InputEventJoypadButton
	if button != null:
		if not button.pressed:
			return Act.NONE
		match button.button_index:
			JOY_BUTTON_DPAD_UP:
				return Act.UP
			JOY_BUTTON_DPAD_DOWN:
				return Act.DOWN
			JOY_BUTTON_A:
				return Act.CONFIRM
			JOY_BUTTON_START:
				return Act.START
		return Act.NONE
	var action := event as InputEventAction
	if action == null or not action.pressed:
		return Act.NONE
	match action.action:
		&"touch_up":
			return Act.UP
		&"touch_down":
			return Act.DOWN
		&"touch_fire":
			return Act.CONFIRM
		&"touch_start":
			return Act.START
	return Act.NONE
```

- [ ] **Шаг 5: `game/ui/skip_input.gd`** — в `is_skip` перед `return false`:

```gdscript
	# The screen's buttons, not its stick: a thumb resting on the stick through the
	# tally must not sweep it away.
	if event is InputEventAction:
		return event.pressed and (event.action == &"touch_fire" \
			or event.action == &"touch_start")
```

И в комментарий класса: «So do the screen's two buttons: a phone has no keys.»

- [ ] **Шаг 6: `./tools/test.sh` зелёный, коммит**

```bash
git add game/platform/touch_device.gd game/ui/ui_input.gd game/ui/skip_input.gd \
  game/tests/platform/test_touch_device.gd game/tests/ui/test_ui_input.gd \
  game/tests/ui/test_skip_input.gd
git commit -m "feat: a touch device is told apart, and a menu reads any device's press"
```

---

### Задача 4: главное меню на телефоне

**Files:**
- Modify: `game/ui/menu.gd`, `game/tests/ui/test_menu_choice.gd`

**Interfaces:**
- Consumes: `UiInput.of`, `TouchDevice.present`.
- Produces: `menu.touch: bool` (поле), `menu.items() -> Array`.

- [ ] **Шаг 1: падающие тесты** — дописать в `test_menu_choice.gd`; заменить в
  существующих тестах `menu.ITEMS.size()` на `menu.items().size()`:

```gdscript
func _action(name: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func test_a_phone_has_no_two_player_item() -> void:
	# Two players at one phone would need two pairs of thumbs on one screen.
	menu.touch = true
	assert_false(menu.items().has("2 PLAYERS"))
	_select(1)
	assert_true(menu._is_network(), "the item after 1 PLAYER on a phone is NETWORK")
	assert_eq(menu.players(), 1)

func test_a_phone_shows_no_keys() -> void:
	menu.touch = true
	assert_true(menu.legend_rows().is_empty())

func test_the_screen_moves_and_confirms() -> void:
	menu.touch = true
	watch_signals(menu)
	menu._unhandled_input(_action(&"touch_down"))
	assert_true(menu._is_network())
	menu._unhandled_input(_action(&"touch_fire"))
	assert_signal_emitted_with_parameters(menu, "finished", [ScreenFlow.Outcome.NET])

func test_start_begins_as_on_the_console() -> void:
	watch_signals(menu)
	menu._unhandled_input(_action(&"touch_start"))
	assert_signal_emitted_with_parameters(menu, "finished", [ScreenFlow.Outcome.CONTINUE])
```

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/ui/menu.gd`**

Рядом с `ITEMS`:

```gdscript
## A phone has one pair of thumbs on one screen: two players there would need two.
const TOUCH_ITEMS := ["1 PLAYER", "NETWORK"]
```

Поле и выбор списка:

```gdscript
## Set once, from the machine; a field so that a test can say "phone".
var touch := TouchDevice.present()

func items() -> Array:
	return TOUCH_ITEMS if touch else ITEMS
```

Ввод:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	match UiInput.of(event):
		UiInput.Act.UP:
			_move(-1)
		UiInput.Act.DOWN:
			_move(1)
		UiInput.Act.CONFIRM, UiInput.Act.START:
			_confirm()
```

По имени пункта, а не по номеру — список теперь двух видов:

```gdscript
func _is_network() -> bool:
	return items()[_choice] == "NETWORK"

func players() -> int:
	return 2 if items()[_choice] == "2 PLAYERS" else 1

func _move(step: int) -> void:
	var count := items().size()
	_choice = (_choice + count + step) % count
	queue_redraw()
```

В `_draw` цикл по `items()` вместо `ITEMS`. В `legend_rows` первой строкой:

```gdscript
	if touch:
		# The keys are not there to name.
		return [] as Array[String]
```

Комментарий у `players()` про «network item once returned 4» сохранить.

- [ ] **Шаг 4: `./tools/test.sh` зелёный, коммит**

```bash
git add game/ui/menu.gd game/tests/ui/test_menu_choice.gd
git commit -m "feat: the title menu answers the screen, and a phone has no two-player item"
```

---

### Задача 5: пауза и уход — выбор из двух пунктов

**Files:**
- Modify: `game/ui/pause.gd`, `game/ui/game.gd:101-115` (`_unhandled_input`),
  `_on_escape`, `_toggle_pause`
- Create: `game/tests/ui/test_pause_choice.gd`

**Interfaces:**
- Consumes: `UiInput.of`.
- Produces: `PauseOverlay.ITEMS`, `PauseOverlay.set_choice(index: int)`; в `game.gd`
  поле `_choice`.

- [ ] **Шаг 1: падающие тесты** — `game/tests/ui/test_pause_choice.gd`

```gdscript
extends GutTest

## The pause and the leave question are a choice of two, driven like a menu: a
## phone and a pad have no Q, and a pad could pause but never quit.

const FRAME := 1.0 / 60.0

var screen: Node = null

func after_each() -> void:
	if screen != null:
		screen.queue_free()
		screen = null

func _build() -> Node:
	var node: Node = load("res://ui/game.tscn").instantiate()
	add_child_autofree(node)
	node.configure(Campaign.new(1, SimConfig.new(), 4242), 1, 0)
	for i in 200:
		node._process(FRAME)
	return node

func _action(name: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func test_start_pauses_and_resumes() -> void:
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	assert_true(screen._paused)
	screen._unhandled_input(_action(&"touch_start"))
	assert_false(screen._paused)

func test_fire_on_resume_resumes() -> void:
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_false(screen._paused)

func test_down_and_fire_quit() -> void:
	screen = _build()
	watch_signals(screen)
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_signal_emitted_with_parameters(screen, "finished", [ScreenFlow.Outcome.QUIT])

func test_a_new_pause_starts_on_resume() -> void:
	# Quit left chosen from the last pause would make the next FIRE end the game.
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_false(screen._paused)

func test_fire_in_play_is_not_a_choice() -> void:
	screen = _build()
	watch_signals(screen)
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_signal_not_emitted(screen, "finished")
	assert_false(screen._paused)

func test_the_items_can_be_drawn() -> void:
	for text in PauseOverlay.ITEMS:
		for i in text.length():
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)
```

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/ui/pause.gd`**

Константы и поле:

```gdscript
const ITEMS := ["RESUME", "QUIT"]
const TEXT_X := 110
const FIRST_Y := 124
const STEP_Y := 16

var _sprites: Texture2D = preload("res://assets/sprites.png")
var _choice := 0
```

`set_shown` сбрасывает выбор, новый `set_choice`:

```gdscript
func set_shown(value: bool, kind: int = Kind.PAUSE) -> void:
	visible = value
	_kind = kind
	_choice = 0
	queue_redraw()

func set_choice(index: int) -> void:
	_choice = index
	queue_redraw()
```

`_draw` — заголовок, пункты, курсор-танк как в меню (подсказки `Q QUIT` / `ESC RESUME`
убрать: Esc и Q работают по-прежнему, а пункты теперь видны):

```gdscript
func _draw() -> void:
	var asking := _kind == Kind.LEAVE
	draw_rect(Rect2(Vector2.ZERO, SCREEN), ASKING_VEIL if asking else VEIL)
	TextPainter.draw_centred(self, _font, "LEAVE MATCH" if asking else "PAUSE", 100)
	for i in ITEMS.size():
		TextPainter.draw_line(self, _font, ITEMS[i], Vector2i(TEXT_X, FIRST_Y + i * STEP_Y),
			Color.WHITE if i == _choice else HINT_TINT)
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2(TEXT_X - 22, FIRST_Y + _choice * STEP_Y - 4)
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)
```

Проверить сигнатуру `TextPainter.draw_line` (четвёртый параметр — цвет, как в
`menu.gd`, `LEGEND_TINT`).

- [ ] **Шаг 4: `game/ui/game.gd`**

Поле рядом с `_leaving`:

```gdscript
var _choice := 0   ## on the pause or the leave question: 0 resume, 1 quit
```

`_unhandled_input` целиком:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.physical_keycode == KEY_Q and (_paused or _leaving):
			_quit_to_menu()
			return
		if key.physical_keycode == KEY_L:
			# Network numbers right on the screen: a screenshot is easier than digging
			# them out of the developer console on somebody else's machine.
			_stats.visible = not _stats.visible
			return
	var act := UiInput.of(event)
	if act == UiInput.Act.BACK or act == UiInput.Act.START:
		_on_escape()
		return
	# In play the arrows and fire belong to the tank; only a question takes them.
	if not (_paused or _leaving):
		return
	match act:
		UiInput.Act.UP, UiInput.Act.DOWN:
			_choice = 1 - _choice
			_pause.set_choice(_choice)
		UiInput.Act.CONFIRM:
			if _choice == 1:
				_quit_to_menu()
			else:
				_on_escape()
```

В `_on_escape` перед `_pause.set_shown(_leaving, …)` и в `_toggle_pause` перед
`_pause.set_shown(_paused)` — `_choice = 0`.

- [ ] **Шаг 5: `./tools/test.sh` зелёный, коммит**

```bash
git add game/ui/pause.gd game/ui/game.gd game/tests/ui/test_pause_choice.gd
git commit -m "feat: the pause and the leave question are a choice, so a pad or a phone can quit"
```

---

### Задача 6: сетевой экран на телефоне и в браузере

**Files:**
- Modify: `game/ui/net.gd`, `game/tests/ui/test_net_screen.gd`

**Interfaces:**
- Consumes: `UiInput.of`, `TouchDevice.present`.
- Produces: поля `net.web: bool`, `net.touch: bool`; `net.items() -> Array`;
  `static func clean_code(text: String) -> String`; `func prefill(code: String) -> void`;
  `func _to_choose() -> void`. Задача 8 добавит поле ввода и «Поделиться» в эти же места.

- [ ] **Шаг 1: падающие тесты** — в `test_net_screen.gd` заменить `net.ITEMS.find` в
  `_pick` на `net.items().find`, дописать:

```gdscript
func _action(name: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func test_a_browser_has_no_lan_items() -> void:
	# A browser cannot accept a connection, and from an https page it will not
	# open a plain one.
	net.web = true
	assert_false(net.items().has("LAN HOST"))
	assert_false(net.items().has("LAN JOIN"))
	assert_true(net.items().has("JOIN ROOM"))

func test_the_desktop_keeps_lan() -> void:
	net.web = false
	assert_true(net.items().has("LAN HOST"))

func test_the_screen_picks_an_item() -> void:
	net.web = true
	net._unhandled_input(_action(&"touch_down"))
	net._unhandled_input(_action(&"touch_down"))
	net._unhandled_input(_action(&"touch_fire"))
	assert_eq(net._mode, net.Mode.CODE_TYPING, "the third item in a browser is JOIN ROOM")

func test_start_leaves_the_screen() -> void:
	watch_signals(net)
	net._unhandled_input(_action(&"touch_start"))
	assert_signal_emitted_with_parameters(net, "finished", [ScreenFlow.Outcome.QUIT])

func test_start_backs_out_of_typing() -> void:
	_pick("JOIN ROOM")
	net._unhandled_input(_action(&"touch_start"))
	assert_eq(net._mode, net.Mode.CHOOSE)

func test_a_code_is_cleaned() -> void:
	assert_eq(net.clean_code("ab3xy9z"), "AB3XY9")
	assert_eq(net.clean_code("A-B_C d"), "ABCD")
	assert_eq(net.clean_code("AB\nCD"), "ABCD", "a line break is not a character of a code")
	assert_eq(net.clean_code(""), "")

func test_a_prefilled_code_waits_for_fire() -> void:
	net.prefill("abc234")
	assert_eq(net._mode, net.Mode.CODE_TYPING)
	assert_eq(net._typed, "ABC234")
	assert_null(net.link, "a link must not join by itself")

func test_every_touch_hint_can_be_drawn() -> void:
	net.touch = true
	for text in net.hints():
		for i in text.length():
			if text[i] == " ":
				continue
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)
		assert_lt(TextPainter.width_of(text), TextPainter.SCREEN_WIDTH)
```

Тест `test_lan_join_asks_for_an_address` оставить: при `web = false` (по умолчанию в
headless) LAN-пункты на месте.

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/ui/net.gd`**

Рядом с `ITEMS`:

```gdscript
## A browser cannot accept a connection, and from an https page it will not open a
## plain one: both ways to meet directly are dead there.
const LAN_ITEMS := ["LAN HOST", "LAN JOIN"]
```

Поля (после `relay_url`):

```gdscript
## Set once, from the machine; fields so that a test can say "browser" or "phone".
var web := OS.has_feature("web")
var touch := TouchDevice.present()
```

Список и действие — по имени пункта:

```gdscript
func items() -> Array:
	if not web:
		return ITEMS
	return ITEMS.filter(func(item: String) -> bool: return not LAN_ITEMS.has(item))

func _act() -> void:
	match items()[_choice]:
		"QUICK GAME":
			_quick_game()
		"CREATE ROOM":
			_create_room()
		"JOIN ROOM":
			_typed = ""
			_mode = Mode.CODE_TYPING
		"LAN HOST":
			_lan_host()
		"LAN JOIN":
			_address = ""
			_mode = Mode.LAN_TYPING
	queue_redraw()
```

Ввод — ключи в режимах набора идут в прежние `_type_code` / `_type_address`, всё
остальное через `UiInput`:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	var typed := key != null and key.pressed and not key.echo
	var act := UiInput.of(event)
	match _mode:
		Mode.CHOOSE:
			_choose(act)
		Mode.CODE_TYPING:
			if typed:
				_type_code(key)
			elif act == UiInput.Act.CONFIRM and _typed.length() == CODE_LEN:
				_join_room()
			elif _is_back(act):
				_to_choose()
		Mode.LAN_TYPING:
			if typed:
				_type_address(key)
			elif _is_back(act):
				_to_choose()
		_:
			if _is_back(act):
				_leave(ScreenFlow.Outcome.QUIT)

func _is_back(act: int) -> bool:
	return act == UiInput.Act.BACK or act == UiInput.Act.START

func _choose(act: int) -> void:
	var count := items().size()
	match act:
		UiInput.Act.UP:
			_choice = (_choice + count - 1) % count
			queue_redraw()
		UiInput.Act.DOWN:
			_choice = (_choice + 1) % count
			queue_redraw()
		UiInput.Act.CONFIRM:
			_act()
		UiInput.Act.BACK, UiInput.Act.START:
			_leave(ScreenFlow.Outcome.QUIT)

func _to_choose() -> void:
	_mode = Mode.CHOOSE
	queue_redraw()
```

В `_type_code` и `_type_address` ветки `KEY_ESCAPE` заменить на `_to_choose()` и `return`.
Добавление символа в `_type_code` — через общее правило:

```gdscript
	var ch := char(event.unicode)
	if ch.length() == 1:
		_typed = clean_code(_typed + ch)
		queue_redraw()
```

Правило кода и заполнение из ссылки:

```gdscript
## One rule for a code however it came — typed, from the phone's own field, or from a
## link someone sent: upper case, only what the font draws, six at most. A link is a
## stranger's text, and it reaches the screen and the server.
static func clean_code(text: String) -> String:
	var out := ""
	for ch in text.to_upper():
		if out.length() == CODE_LEN:
			break
		if ch != " " and TextPainter.glyph_index(ch) >= 0:
			out += ch
	return out

## The code a link carried: the join screen with it in, waiting for FIRE — a browser
## plays no sound before a tap, and a link is no reason to join anything unasked.
func prefill(code: String) -> void:
	_typed = clean_code(code)
	_mode = Mode.CODE_TYPING
	queue_redraw()
```

Проверить, что `TextPainter.glyph_index(".")` и `(":")` ≥ 0 — точка и двоеточие в коде
допустимы по шрифту, как и раньше при наборе; сервер откажет таким кодом сам (`NO SUCH
ROOM`), это прежнее поведение.

Подсказки — функцией, чтобы тест проверил все:

```gdscript
func _hint(desk: String, phone: String) -> String:
	return phone if touch else desk

## Every hint this screen can show here, for the test that they can be drawn.
func hints() -> Array[String]:
	return [
		_hint("ESC BACK", "START BACK"),
		_hint("ESC CANCEL", "START CANCEL"),
		_hint("ENTER JOIN  ESC BACK", "FIRE JOIN  START BACK"),
		_hint("ENTER CONNECT  ESC BACK", "START BACK"),
	] as Array[String]
```

В `_draw` заменить строковые литералы подсказок на `_hint(...)` с теми же парами.

- [ ] **Шаг 4: `./tools/test.sh` зелёный, коммит**

```bash
git add game/ui/net.gd game/tests/ui/test_net_screen.gd
git commit -m "feat: the network screen answers a pad and the screen, and a browser has no LAN"
```

---

### Задача 7: кнопки на экране, раскладка, `ROTATE PHONE`

**Files:**
- Create: `game/ui/stage_layout.gd`, `game/ui/touch_controls.gd`, `game/ui/rotate_hint.gd`,
  `game/tests/ui/test_stage_layout.gd`, `game/tests/ui/test_touch_controls.gd`
- Modify: `game/ui/app.gd`

**Interfaces:**
- Consumes: `Touch.compose`, `Touch.bits`, `TouchDevice.present`, действия `touch_*`.
- Produces: `StageLayout.offset_x(viewport_width: float) -> int`,
  `StageLayout.portrait(window: Vector2i) -> bool`; `TouchControls.steer(direction: int)`,
  `TouchControls.place(view: Vector2)`, `TouchControls.stick_rect() -> Rect2`,
  `TouchControls.fire_centre() -> Vector2`; `RotateHint.TEXT`.

- [ ] **Шаг 1: падающие тесты**

`game/tests/ui/test_stage_layout.gd`:

```gdscript
extends GutTest

## Where the picture stands when the viewport is widened for the thumbs.

func test_the_picture_is_centred() -> void:
	# An iPhone in landscape at scale four: 633 base pixels across.
	assert_eq(StageLayout.offset_x(633.0), 188)

func test_a_viewport_no_wider_than_the_picture_has_no_offset() -> void:
	assert_eq(StageLayout.offset_x(256.0), 0)
	assert_eq(StageLayout.offset_x(200.0), 0, "a narrow window must not push it off")

func test_portrait() -> void:
	assert_true(StageLayout.portrait(Vector2i(1170, 2532)))
	assert_false(StageLayout.portrait(Vector2i(2532, 1170)))
	assert_false(StageLayout.portrait(Vector2i(1000, 1000)), "a square plays")
```

`game/tests/ui/test_touch_controls.gd`:

```gdscript
extends GutTest

## The layer that turns the engine's stick and buttons into `touch_*` actions: one
## event a change, so a menu sees one flick as one press, and nothing is left held.

var controls: TouchControls

func before_each() -> void:
	controls = TouchControls.new()
	add_child_autofree(controls)

func after_each() -> void:
	controls.steer(0)
	for action in Touch.ACTIONS:
		Input.action_release(action)
	Input.action_release(&"touch_start")
	Input.flush_buffered_events()

func test_a_direction_is_held_until_it_changes() -> void:
	controls.steer(Types.IN_UP)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), Types.IN_UP)
	controls.steer(Types.IN_LEFT)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), Types.IN_LEFT, "the old direction was left held")
	controls.steer(0)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), 0)

func test_the_same_direction_sends_nothing_new() -> void:
	var seen: Array = []
	var spy := _Spy.new(seen)
	add_child_autofree(spy)
	controls.steer(Types.IN_DOWN)
	controls.steer(Types.IN_DOWN)
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_eq(seen.count("touch_down"), 1, "a menu would move twice")

func test_the_controls_stay_off_the_picture() -> void:
	# An iPhone in landscape: 633 across, the picture from 188 to 444.
	controls.place(Vector2(633, 240))
	var stick := controls.stick_rect()
	assert_lte(stick.end.x, 188.0, "the stick covers the field")
	assert_gte(controls.fire_centre().x - TouchControls.BUTTON_RADIUS, 444.0,
		"FIRE covers the panel")

func test_the_labels_can_be_drawn() -> void:
	for text in [TouchControls.FIRE_TEXT, TouchControls.START_TEXT, RotateHint.TEXT]:
		for i in text.length():
			if text[i] == " ":
				continue
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)

class _Spy extends Node:
	var _seen: Array
	func _init(seen: Array) -> void:
		_seen = seen
	func _input(event: InputEvent) -> void:
		if event is InputEventAction and event.pressed:
			_seen.append(String(event.action))
```

Если `_Spy` не получает событие в headless за один кадр — дождаться двух
`process_frame`; разведка в планировании (2026-09-28) показала, что
`Input.parse_input_event(InputEventAction)` доходит до `_input` и меняет
`Input.is_action_pressed` в headless за кадр.

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/ui/stage_layout.gd`**

```gdscript
class_name StageLayout

## Where the 256×240 picture stands in a viewport widened for the thumbs. On a touch
## screen the viewport keeps its height and takes the window's width, so the strips
## beside the picture are free for the stick and the buttons; the picture stays in
## the middle, at a whole scale as everywhere else.

const BASE := Vector2i(256, 240)

static func offset_x(viewport_width: float) -> int:
	return maxi(0, (int(viewport_width) - BASE.x) / 2)

## Taller than wide. A square plays: an iPad held either way is near enough.
static func portrait(window: Vector2i) -> bool:
	return window.y > window.x
```

- [ ] **Шаг 4: `game/ui/touch_controls.gd`**

```gdscript
class_name TouchControls
extends CanvasLayer

## The stick and two buttons on a touch screen, in the strips beside the picture.
## The engine's own nodes take the fingers — several at once, one sliding off a
## button — and this layer turns what they report into `touch_*` actions, the only
## thing the rest of the game reads. A direction becomes an event when it changes,
## so a menu sees a flick of the stick as one press.
##
## The engine draws neither: its stick is given empty styles and the buttons no
## texture, and the pixels are drawn here — a cross like the console's pad and two
## round buttons — so the controls look like the rest of the game.

const STICK_ACTIONS := [&"touch_stick_left", &"touch_stick_right",
	&"touch_stick_up", &"touch_stick_down"]
const DIRECTION_ACTIONS := {
	Types.IN_UP: &"touch_up", Types.IN_DOWN: &"touch_down",
	Types.IN_LEFT: &"touch_left", Types.IN_RIGHT: &"touch_right",
}
const STICK_SIZE := 72.0          ## the stick's reach, in base pixels
const STICK_AREA := 144.0         ## where a thumb may land to take it
const CELL := 14                  ## one arm of the drawn cross
const BUTTON_RADIUS := 18
const FIRE_TEXT := "FIRE"
const START_TEXT := "START"
const IDLE := Color(1, 1, 1, 0.35)
const LIT := Color(1.0, 0.85, 0.2, 0.8)

var _font: Texture2D = preload("res://assets/font.png")
var _direction := 0
var _held := {}                   ## action → true while its button is down
var _stick: VirtualJoystick
var _fire: TouchScreenButton
var _start: TouchScreenButton
var _art: Node2D
var _stick_centre := Vector2.ZERO

func _ready() -> void:
	_stick = VirtualJoystick.new()
	_stick.joystick_mode = VirtualJoystick.JOYSTICK_DYNAMIC
	_stick.joystick_size = STICK_SIZE
	_stick.tip_size = STICK_SIZE / 2.0
	_stick.deadzone_ratio = 0.0   # Touch.compose has its own
	_stick.action_left = STICK_ACTIONS[0]
	_stick.action_right = STICK_ACTIONS[1]
	_stick.action_up = STICK_ACTIONS[2]
	_stick.action_down = STICK_ACTIONS[3]
	for style in ["normal_joystick", "normal_tip", "pressed_joystick", "pressed_tip"]:
		_stick.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	add_child(_stick)
	_fire = _button(&"touch_fire", true)
	_start = _button(&"touch_start", false)
	_art = Node2D.new()
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_art.draw.connect(_paint)
	add_child(_art)
	place(get_viewport().get_visible_rect().size)

## FIRE takes a thumb sliding onto it — from the edge of the screen, from START — as
## a press; START does not, or a thumb crossing it on the way to FIRE would pause.
func _button(action: StringName, passby: bool) -> TouchScreenButton:
	var button := TouchScreenButton.new()
	var shape := CircleShape2D.new()
	shape.radius = BUTTON_RADIUS + 4   # a thumb is bigger than the drawing
	button.shape = shape
	button.shape_centered = true
	button.passby_press = passby
	button.pressed.connect(func() -> void: _send(action, true))
	button.released.connect(func() -> void: _send(action, false))
	add_child(button)
	return button

func _process(_delta: float) -> void:
	var stick := Input.get_vector(STICK_ACTIONS[0], STICK_ACTIONS[1],
		STICK_ACTIONS[2], STICK_ACTIONS[3], 0.0)
	steer(Touch.compose(stick, _direction))

## A direction as actions, only when it changes: the old one let go, the new one
## pressed.
func steer(direction: int) -> void:
	if direction == _direction:
		return
	if _direction != 0:
		_send(DIRECTION_ACTIONS[_direction], false)
	_direction = direction
	if direction != 0:
		_send(DIRECTION_ACTIONS[direction], true)

func _send(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
	if pressed:
		_held[action] = true
	else:
		_held.erase(action)
	if _art != null:
		_art.queue_redraw()

## The stick in the middle of the left strip, the buttons in the middle of the right
## one, START above FIRE. A strip narrower than a control lets it overlap the edge of
## the picture rather than leave the screen.
func place(view: Vector2) -> void:
	var strip := float(StageLayout.offset_x(view.x))
	var middle := view.y * 0.6
	_stick_centre = Vector2(maxf(strip / 2.0, STICK_AREA / 2.0), middle)
	_stick.size = Vector2(STICK_AREA, STICK_AREA)
	_stick.position = _stick_centre - _stick.size / 2.0
	var right := view.x - maxf(strip / 2.0, BUTTON_RADIUS * 2.0)
	_fire.position = Vector2(right, middle + 24)
	_start.position = Vector2(right, middle - 36)
	_art.queue_redraw()

func stick_rect() -> Rect2:
	return Rect2(_stick.position, _stick.size)

func fire_centre() -> Vector2:
	return _fire.position

func _paint() -> void:
	_cross(_stick_centre)
	_disc(_fire.position, BUTTON_RADIUS, LIT if _held.has(&"touch_fire") else IDLE)
	_disc(_start.position, BUTTON_RADIUS - 6, LIT if _held.has(&"touch_start") else IDLE)
	_label(FIRE_TEXT, _fire.position + Vector2(0, BUTTON_RADIUS + 4))
	_label(START_TEXT, _start.position + Vector2(0, BUTTON_RADIUS - 2))

## The console's cross: a centre and four arms, the one held lit.
func _cross(centre: Vector2) -> void:
	var half := CELL / 2.0
	_art.draw_rect(Rect2(centre - Vector2(half, half), Vector2(CELL, CELL)), IDLE)
	for bit in DIRECTION_ACTIONS:
		var way := Vector2.ZERO
		match bit:
			Types.IN_UP:
				way = Vector2(0, -1)
			Types.IN_DOWN:
				way = Vector2(0, 1)
			Types.IN_LEFT:
				way = Vector2(-1, 0)
			Types.IN_RIGHT:
				way = Vector2(1, 0)
		var at := centre + way * CELL - Vector2(half, half)
		_art.draw_rect(Rect2(at, Vector2(CELL, CELL)), LIT if bit == _direction else IDLE)

## A filled circle out of whole-pixel rows: an antialiased one would be the only
## smooth edge in the game.
func _disc(centre: Vector2, radius: int, color: Color) -> void:
	for dy in range(-radius, radius + 1):
		var half := int(sqrt(float(radius * radius - dy * dy)))
		_art.draw_rect(Rect2(centre.x - half, centre.y + dy, half * 2 + 1, 1), color)

func _label(text: String, top_centre: Vector2) -> void:
	var at := Vector2i(int(top_centre.x) - TextPainter.width_of(text) / 2, int(top_centre.y))
	TextPainter.draw_line(_art, _font, text, at, IDLE)
```

Проверить: `TextPainter.draw_line` принимает `CanvasItem` первым параметром (как в
`menu.gd`, где передаётся `self`), иначе рисовать через `self`-обёртку.

- [ ] **Шаг 5: `game/ui/rotate_hint.gd`**

```gdscript
class_name RotateHint
extends CanvasLayer

## Held upright, a phone has no strips beside the picture for the thumbs, and the
## picture itself would be a third of the screen. The game asks to be turned instead.

const TEXT := "ROTATE PHONE"

var _font: Texture2D = preload("res://assets/font.png")
var _art: Node2D

func _ready() -> void:
	layer = 10
	_art = Node2D.new()
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_art.draw.connect(_paint)
	add_child(_art)

func refresh() -> void:
	_art.queue_redraw()

func _paint() -> void:
	var view := _art.get_viewport().get_visible_rect().size
	_art.draw_rect(Rect2(Vector2.ZERO, view), Color.BLACK)
	var at := Vector2i(int(view.x) / 2 - TextPainter.width_of(TEXT) / 2, int(view.y) / 2 - 4)
	TextPainter.draw_line(_art, _font, TEXT, at)
```

- [ ] **Шаг 6: `game/ui/app.gd`**

Поля:

```gdscript
var _touch: TouchControls = null
var _rotate: RotateHint = null
```

В `_ready` сразу после `_fit_window()`:

```gdscript
	if TouchDevice.present():
		_fit_touch()
```

Новые функции (после `_toggle_fullscreen`):

```gdscript
## A phone keeps the picture's height and gives the rest of the width to the thumbs:
## the stick and the buttons stand in the strips a square picture leaves on a
## landscape screen. Laid out again whenever the window changes — a browser's bars
## come and go, and the phone turns.
func _fit_touch() -> void:
	var root := get_tree().root
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
	# Beyond the picture was the engine's letterbox; now it is the clear colour.
	RenderingServer.set_default_clear_color(Color.BLACK)
	_touch = TouchControls.new()
	add_child(_touch)
	_rotate = RotateHint.new()
	add_child(_rotate)
	root.size_changed.connect(_relayout)
	_relayout()

func _relayout() -> void:
	if _touch == null:
		return
	var view := get_viewport().get_visible_rect().size
	var screen := _current as Node2D
	if screen != null:
		screen.position.x = StageLayout.offset_x(view.x)
	_touch.place(view)
	_rotate.visible = StageLayout.portrait(DisplayServer.window_get_size())
	_rotate.refresh()
```

В `_show` сразу после `add_child(_current)`:

```gdscript
	_relayout()
```

- [ ] **Шаг 7: `./tools/test.sh` зелёный**

- [ ] **Шаг 8: глазами в Chrome на маке**

```bash
./tools/build.sh Web
(cd build/web && python3 -m http.server 8060) &
```

Chrome → `http://localhost:8060/` → DevTools → Toggle device toolbar → iPhone 14 Pro,
landscape → перезагрузить страницу (признак сенсорного читается один раз при старте).
Проверить: картинка по центру, крест слева, FIRE и START справа, пройти меню крестом и
FIRE, начать уровень, поехать и выстрелить, START — пауза, вниз + FIRE — выход. Повернуть
в портрет — `ROTATE PHONE`, обратно — игра на месте. Без эмуляции устройства — всё как
раньше, кнопок нет. Сделать скриншоты, показать пользователю в отчёте задачи.

Если `VirtualJoystick` не отдаёт силу действий `touch_stick_*` (танк не едет, хотя FIRE
работает) — не чинить обходом: остановиться и описать, что видно; это вопрос к выбору
«готовые узлы» и решает пользователь.

- [ ] **Шаг 9: коммит**

```bash
git add game/ui/stage_layout.gd game/ui/touch_controls.gd game/ui/rotate_hint.gd \
  game/ui/app.gd game/tests/ui/test_stage_layout.gd game/tests/ui/test_touch_controls.gd
git commit -m "feat: a stick and two buttons beside the picture on a touch screen"
```

---

### Задача 8: код комнаты — поле телефона, ссылка, «Поделиться»

**Files:**
- Create: `game/platform/code_field.gd`, `game/platform/room_link.gd`,
  `game/tests/platform/test_room_link.gd`
- Modify: `game/platform/relay_config.gd` (`_query_value` → `query_value`,
  `_page_url` → `page_url`), `game/tests/platform/test_relay_config.gd` (если зовёт
  старые имена), `game/ui/net.gd`, `game/ui/app.gd`, `game/tests/ui/test_net_screen.gd`

**Interfaces:**
- Consumes: `net.clean_code`, `net.prefill`, `net._to_choose`, `net.touch`, `net.web`.
- Produces: `RoomLink.code_in(page: String) -> String`,
  `RoomLink.url_for(page: String, code: String) -> String`,
  `RoomLink.send(url: String) -> String` (`"shared"`, `"copied"` или `""`);
  `CodeField` (Node) с сигналами `changed(text: String)`, `submitted(text: String)` и
  методами `open(text: String) -> bool`, `close() -> void`;
  `RelayConfig.query_value`, `RelayConfig.page_url`.

- [ ] **Шаг 1: падающие тесты**

`game/tests/platform/test_room_link.gd`:

```gdscript
extends GutTest

## A room's code carried in the page address, from one phone's share sheet to
## another's browser.

func test_a_code_is_read_from_the_link() -> void:
	assert_eq(RoomLink.code_in("https://base13.example/?room=ABC234"), "ABC234")
	assert_eq(RoomLink.code_in("https://base13.example/index.html?x=1&room=ABC234#top"),
		"ABC234")

func test_no_code_is_empty() -> void:
	assert_eq(RoomLink.code_in("https://base13.example/"), "")
	assert_eq(RoomLink.code_in("https://base13.example/?relay=ws"), "")
	assert_eq(RoomLink.code_in(""), "")

func test_a_code_in_the_link_is_cleaned() -> void:
	# A link is a stranger's text. What it carries reaches the screen and the
	# server only through the same rule as a typed code.
	var raw := RoomLink.code_in("https://base13.example/?room=ab%0Ac2%2034xyz")
	assert_eq(load("res://ui/net.gd").clean_code(raw), "ABC234")

func test_the_link_is_the_page_with_the_code() -> void:
	assert_eq(RoomLink.url_for("https://base13.example/index.html?selftest#x", "ABC234"),
		"https://base13.example/index.html?room=ABC234")
	assert_eq(RoomLink.url_for("https://base13.example/", "ABC234"),
		"https://base13.example/?room=ABC234")

func test_nothing_to_share_off_the_web() -> void:
	assert_eq(RoomLink.send("https://base13.example/?room=ABC234"), "")
```

В `test_net_screen.gd` дописать:

```gdscript
func test_keys_are_ignored_while_the_field_is_open() -> void:
	# The phone's keyboard types into the page's field; the engine may hear the
	# same keys. Taken from both, every letter would land twice.
	_pick("JOIN ROOM")
	net._field_open = true
	net._unhandled_input(_press(0, "A".unicode_at(0)))
	assert_eq(net._typed, "")

func test_the_field_fills_the_code() -> void:
	_pick("JOIN ROOM")
	net._on_field_changed("abc2")
	assert_eq(net._typed, "ABC2")

func test_a_short_code_from_the_field_does_not_join() -> void:
	_pick("JOIN ROOM")
	net._on_field_submitted("abc")
	assert_null(net.link)
	assert_eq(net._mode, net.Mode.CODE_TYPING)

func test_the_field_stays_shut_off_a_phone() -> void:
	net.touch = false
	_pick("JOIN ROOM")
	assert_false(net._field_open)
```

- [ ] **Шаг 2: запустить — падает**

- [ ] **Шаг 3: `game/platform/relay_config.gd`**

Переименовать `_query_value` → `query_value` и `_page_url` → `page_url` (оба `static`),
поправить вызовы внутри файла (`url()`, `from_page`) и в тестах, если есть:

```bash
grep -rn "_query_value\|_page_url" game --include='*.gd'
```

- [ ] **Шаг 4: `game/platform/room_link.gd`**

```gdscript
class_name RoomLink

## A room's code carried in the page address, `…/?room=ABC234`: sent from one phone's
## share sheet, opened in another's browser, and the game starts on the join screen
## with the code in. It never joins by itself — see NetScreen.prefill.

const KEY := "room"

## The code as the link carries it: raw, a stranger's text. It goes through
## `clean_code` before anything shows or sends it.
static func code_in(page: String) -> String:
	var mark := page.find("?")
	if mark < 0:
		return ""
	var query := page.substr(mark + 1)
	var anchor := query.find("#")
	if anchor >= 0:
		query = query.substr(0, anchor)
	return RelayConfig.query_value(query, KEY)

## This page, with the code and nothing else behind it: a `?selftest` or a `?relay`
## of our own has no business in a friend's link.
static func url_for(page: String, code: String) -> String:
	var base := page
	for mark in ["?", "#"]:
		var at := base.find(mark)
		if at >= 0:
			base = base.substr(0, at)
	return base + "?" + KEY + "=" + code

## Hands the link to the phone's share sheet, or copies it where there is none.
## "shared", "copied", or "" with nothing to do it with. The browser answers later
## and may say no — a share cancelled, a clipboard refused — and neither is worth a
## word on screen: the code is right there, large enough to dictate.
static func send(url: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var how = JavaScriptBridge.eval(SEND % JSON.stringify(url), true)
	return how if typeof(how) == TYPE_STRING else ""

const SEND := """(function (url) {
  if (navigator.share) {
    navigator.share({ url: url }).catch(function () {});
    return 'shared';
  }
  if (navigator.clipboard) {
    navigator.clipboard.writeText(url).catch(function () {});
    return 'copied';
  }
  return '';
})(%s)"""
```

- [ ] **Шаг 5: `game/platform/code_field.gd`**

```gdscript
class_name CodeField
extends Node

## A real text field over the game, for a room code on a phone. It has to be the
## page's own and tapped by the person: iOS opens its keyboard only for a field
## focused inside the tap itself, and the engine reads a tap a frame later, so a
## field the game focused would sit there with no keyboard.
##
## What is typed comes back as it is; the screen cleans it.

signal changed(text: String)
signal submitted(text: String)

const ID := "room-code-field"

## Kept, or the browser would be left calling callbacks already freed.
var _on_input: JavaScriptObject = null
var _on_enter: JavaScriptObject = null

## False off the web: there is no page to put a field on.
func open(text: String) -> bool:
	if not OS.has_feature("web"):
		return false
	_on_input = JavaScriptBridge.create_callback(_input_came)
	_on_enter = JavaScriptBridge.create_callback(_enter_came)
	var window := JavaScriptBridge.get_interface("window")
	window.roomCodeInput = _on_input
	window.roomCodeEnter = _on_enter
	JavaScriptBridge.eval(OPEN % [JSON.stringify(ID), JSON.stringify(text)])
	return true

func close() -> void:
	if not OS.has_feature("web") or _on_input == null:
		return
	JavaScriptBridge.eval(CLOSE % JSON.stringify(ID))
	_on_input = null
	_on_enter = null

func _exit_tree() -> void:
	close()

func _input_came(args: Array) -> void:
	changed.emit(str(args[0]) if not args.is_empty() else "")

func _enter_came(args: Array) -> void:
	submitted.emit(str(args[0]) if not args.is_empty() else "")

const OPEN := """(function (id, text) {
  var old = document.getElementById(id);
  if (old) old.remove();
  var f = document.createElement('input');
  f.id = id;
  f.value = text;
  f.maxLength = 6;
  f.placeholder = 'ROOM CODE';
  f.autocapitalize = 'characters';
  f.autocomplete = 'off';
  f.spellcheck = false;
  f.enterKeyHint = 'go';
  f.style.cssText = 'position:fixed;left:50%;top:12px;transform:translateX(-50%);' +
    'z-index:10;width:8em;padding:8px;font:bold 28px monospace;letter-spacing:6px;' +
    'text-align:center;text-transform:uppercase;color:#ffd933;background:#000;' +
    'border:2px solid #fff;border-radius:0;';
  f.addEventListener('input', function () { window.roomCodeInput(f.value); });
  f.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); window.roomCodeEnter(f.value); }
  });
  document.body.appendChild(f);
})(%s, %s)"""

const CLOSE := """(function (id) {
  var f = document.getElementById(id);
  if (f) { f.blur(); f.remove(); }
})(%s)"""
```

- [ ] **Шаг 6: `game/ui/net.gd` — поле, «Поделиться»**

Поля:

```gdscript
var _field: CodeField = null
## Whether the page's own field holds the code: the keys the engine hears are then
## the same letters a second time.
var _field_open := false
## What the last share came to: "copied" puts LINK COPIED on screen.
var _shared := ""
```

Открытие поля — при входе в набор кода (в `_act` ветка `"JOIN ROOM"` и в `prefill`,
после `_mode = Mode.CODE_TYPING`):

```gdscript
	_open_field()
```

```gdscript
## On a phone the code is typed into the page's own field, with the phone's keyboard.
func _open_field() -> void:
	if not touch:
		return
	if _field == null:
		_field = CodeField.new()
		add_child(_field)
		_field.changed.connect(_on_field_changed)
		_field.submitted.connect(_on_field_submitted)
	_field_open = _field.open(_typed)

func _close_field() -> void:
	if _field != null:
		_field.close()
	_field_open = false

func _on_field_changed(text: String) -> void:
	_typed = clean_code(text)
	queue_redraw()

func _on_field_submitted(text: String) -> void:
	_typed = clean_code(text)
	queue_redraw()
	if _typed.length() == CODE_LEN:
		_join_room()
```

В `_unhandled_input`, ветка `Mode.CODE_TYPING`: `if typed and not _field_open:`.
В `_to_choose()` и в начале `_join_room()` — `_close_field()`. Отдельный `_exit_tree`
не нужен: `CodeField` закрывается сам, уходя из дерева вместе с экраном.

«Поделиться» на ожидании созданной комнаты — в `_unhandled_input` отдельная ветка перед
`_:`:

```gdscript
		Mode.ROOM_WAIT:
			if act == UiInput.Act.CONFIRM and web:
				_share()
			elif _is_back(act):
				_leave(ScreenFlow.Outcome.QUIT)
```

```gdscript
func _share() -> void:
	_shared = RoomLink.send(RoomLink.url_for(RelayConfig.page_url(), link.code))
	queue_redraw()
```

В `_draw`, `Mode.ROOM_WAIT`, вместо строки `"TELL IT TO YOUR FRIEND"` в вебе:

```gdscript
			if web:
				TextPainter.draw_centred(self, _font,
					"LINK COPIED" if _shared == "copied" else _hint("ENTER SHARE LINK", "FIRE SHARE LINK"),
					144, HINT_TINT)
			else:
				TextPainter.draw_centred(self, _font, "TELL IT TO YOUR FRIEND", 144, HINT_TINT)
```

Добавить `"LINK COPIED"`, `_hint("ENTER SHARE LINK", "FIRE SHARE LINK")` в `hints()`.

- [ ] **Шаг 7: `game/ui/app.gd` — ссылка открывает экран входа**

Поле:

```gdscript
## A room's code the page was opened with: the game starts on the join screen with
## it in. Used once — back in the menu, the network screen opens as usual.
var _room_code := ""
```

В `_ready` перед `_show(_screen)` (после выхода по selftest):

```gdscript
	_room_code = RoomLink.code_in(RelayConfig.page_url())
	if _room_code != "":
		_screen = ScreenFlow.Screen.NET
```

В `_show` после блока `if _current.has_method("configure")`:

```gdscript
	if screen == ScreenFlow.Screen.NET and _room_code != "":
		_current.prefill(_room_code)
		_room_code = ""
```

- [ ] **Шаг 8: `./tools/test.sh` зелёный, коммит**

```bash
git add game/platform/code_field.gd game/platform/room_link.gd game/platform/relay_config.gd \
  game/ui/net.gd game/ui/app.gd game/tests/platform/test_room_link.gd \
  game/tests/ui/test_net_screen.gd game/tests/platform/test_relay_config.gd
git commit -m "feat: a room code from the phone's keyboard, from a link, and a link to share"
```

---

### Задача 9: установка на домашний экран, весь экран на Android, кэш на сервере

**Files:**
- Modify: `tools/gen_sprites.py`, `game/assets/atlas.manifest` (генерируется),
  `game/export_presets.cfg` (`[preset.3.options]`), `server/main.go` (`noCacheIndex`),
  `server/server_test.go`, `game/ui/app.gd`
- Create: `game/assets/icon_144.png`, `icon_180.png`, `icon_512.png` (+ `.import`)

- [ ] **Шаг 1: падающий Go-тест** — в `server/server_test.go` после
  `TestIndexIsNotCachedButTheRestIs`:

```go
func TestPwaFilesAreNotCached(t *testing.T) {
	// The service worker decides which copy of the game a home-screen install runs.
	// Cached itself, it would keep a phone on an old release after a new one is out.
	dir := writeStatic(t)
	for _, name := range []string{"index.service.worker.js", "index.manifest.json"} {
		if err := os.WriteFile(dir+"/"+name, []byte("{}"), 0o644); err != nil {
			t.Fatalf("file was not written: %v", err)
		}
	}
	addr, stop := startServerWithStatic(t, dir)
	defer stop()

	for _, name := range []string{"index.service.worker.js", "index.manifest.json"} {
		response, err := http.Get("http://" + addr + "/" + name)
		if err != nil {
			t.Fatalf("%s was not served: %v", name, err)
		}
		response.Body.Close()
		if response.Header.Get("Cache-Control") != "no-cache" {
			t.Fatalf("%s must forbid caching, got %q", name, response.Header.Get("Cache-Control"))
		}
	}
}
```

```bash
(cd server && GOTOOLCHAIN=local go test -count=1 -run 'TestPwa|TestIndexIsNot' ./...)
```

Ожидается: FAIL у `TestPwaFilesAreNotCached`.

- [ ] **Шаг 2: `server/main.go`** — `noCacheIndex`:

```go
// noCacheIndex forbids caching the page itself and the two files that decide which
// copy of the game an installed one runs: the service worker and its manifest.
// Godot's files carry no fingerprint in their names, so a cached index.html would
// mean an updated game never reaches the player at all, and a cached service worker
// would do the same to a phone that put the game on its home screen. Everything
// else only benefits from caching: the names are stable and the files are large.
func noCacheIndex(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if p == "/" || strings.HasSuffix(p, "/index.html") ||
			strings.HasSuffix(p, ".service.worker.js") ||
			strings.HasSuffix(p, ".manifest.json") {
			w.Header().Set("Cache-Control", "no-cache")
		}
		next.ServeHTTP(w, r)
	})
}
```

Go-тесты зелёные; `./tools/check_server_neutral.sh` зелёный.

- [ ] **Шаг 3: иконки в `tools/gen_sprites.py`**

`icon_rows` параметризовать размером и множителем (значения по умолчанию — нынешние):

```python
# The sizes a home-screen install asks for, each with its own whole multiplier: the
# tank takes about three quarters of the square, like the 256 icon.
PWA_ICONS = {"icon_144": (144, 7), "icon_180": (180, 9), "icon_512": (512, 24)}


def icon_rows(size=ICON_SIZE, scale=ICON_SCALE):
```

Внутри функции заменить `ICON_SIZE` на `size`, `ICON_SCALE` на `scale`. В `build()`:

```python
    for name, (size, scale) in PWA_ICONS.items():
        out[name] = (size, size, icon_rows(size, scale))
```

```bash
cd tools && python3 gen_sprites.py && python3 gen_sprites.py --check && cd ..
$GODOT --headless --path game --import
git status --short game/assets   # три новых png, их .import и манифест
```

- [ ] **Шаг 4: пресет** — в `game/export_presets.cfg`, `[preset.3.options]`, заменить
  `progressive_web_app/enabled=false` на:

```ini
progressive_web_app/enabled=true
progressive_web_app/ensure_cross_origin_isolation_headers=false
progressive_web_app/offline_page=""
progressive_web_app/display=0
progressive_web_app/orientation=1
progressive_web_app/icon_144x144="res://assets/icon_144.png"
progressive_web_app/icon_180x180="res://assets/icon_180.png"
progressive_web_app/icon_512x512="res://assets/icon_512.png"
progressive_web_app/background_color=Color(0, 0, 0, 1)
```

`display=0` — Fullscreen, `orientation=1` — Landscape. Потоков в сборке нет, поэтому
изоляция не нужна и выключена.

- [ ] **Шаг 5: проверить сборку и версию кэша**

```bash
./tools/build.sh Web
ls build/web | grep -E 'manifest|service.worker|offline|144|180|512'
grep -E '"display"|"orientation"' build/web/index.manifest.json
grep -n "CACHE_VERSION" build/web/index.service.worker.js | head -2
sleep 2 && ./tools/build.sh Web
grep -n "CACHE_VERSION =" build/web/index.service.worker.js | head -1
```

Ожидается: манифест с `"display": "fullscreen"` и `"orientation": "landscape"`, service
worker, иконки. Если имена опций в пресете неверны, Godot молча возьмёт значения по
умолчанию: сверить с опциями в редакторе (Project → Export → Web) и поправить ключи.

`CACHE_VERSION` двух сборок **должен различаться**. Если он одинаковый (только версия
движка), новый релиз не дойдёт до установленной игры: добавить в `tools/build.sh` после
экспорта веба:

```bash
# A home-screen install runs what its service worker cached, and the worker
# throws that away only when CACHE_VERSION changes. Godot writes the engine's
# version there, the same for every release of the game.
if [ -f build/web/index.service.worker.js ]; then
  stamp="$(git rev-parse --short HEAD)-$(date +%s)"
  sed -i.bak "s/const CACHE_VERSION = '\([^']*\)'/const CACHE_VERSION = '\1-$stamp'/" \
    build/web/index.service.worker.js
  rm -f build/web/index.service.worker.js.bak
fi
```

и проверить заново. Что оказалось — записать в спеку, «Что проверено».

- [ ] **Шаг 6: весь экран на Android по первому касанию** — `game/ui/app.gd`

Поле:

```gdscript
## Android's browser can hide its bars when asked from a tap; an iPhone's cannot,
## there the home-screen install is the way.
var _wants_fullscreen := false
```

В `_fit_touch()`:

```gdscript
	_wants_fullscreen = ClientInfo.platform_name(OS.get_name(),
		Callable(OS, "has_feature")) == "web_android"
```

```gdscript
func _input(event: InputEvent) -> void:
	if _wants_fullscreen and event is InputEventScreenTouch and event.pressed:
		_wants_fullscreen = false
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
```

- [ ] **Шаг 7: `./tools/test.sh` зелёный, коммит**

```bash
git add tools/gen_sprites.py game/assets game/export_presets.cfg server/main.go \
  server/server_test.go game/ui/app.gd tools/build.sh
git commit -m "feat: the game installs to a phone's home screen, and Android goes full screen"
```

---

### Задача 10: живая проверка и документы (стоп-точка)

**Files:**
- Modify: `docs/specs/2026-09-28-mobile-web-design.md` (раздел «Что проверено», Caddy →
  TLS сервера), `AGENTS.md`, `README.md`

- [ ] **Шаг 1: сборка и адрес**

```bash
just phone --build
```

- [ ] **Шаг 2: проверка с пользователем — СТОП**

Дать пользователю адрес и список; ждать ответа по каждому пункту:

1. iPhone, Safari: меню крестом и FIRE, `1 PLAYER`, уровень пройден или проигран, звук,
   START — пауза, вниз + FIRE — выход в меню.
2. Повернуть в горизонталь и обратно — игра на месте, поле квадратное, показатели
   под полем, кнопки не перекрывают картинку. Проверить нажатие, удержание и отпускание
   креста, FIRE и START; START по центру в вертикали.
3. Сеть, ноутбук ↔ iPhone: `QUICK GAME` с обеих сторон; `CREATE ROOM` на ноутбуке и
   `JOIN ROOM` на iPhone с набором кода системной клавиатурой.
4. `CREATE ROOM` на iPhone → FIRE → «Поделиться» → ссылка ноутбуку → открывается экран
   входа с кодом → FIRE → игра.
5. «На экран Домой» в Safari → запуск с иконки без адресной строки.
6. Ноутбук: игра как прежде, клавиатура и геймпад, кнопок нет, в браузере нет LAN.

Сетевая игра с ноутбуком идёт через тот же сервер: ноутбук открывает
`https://<ip>:8443/` в браузере (сертификат mkcert на маке доверенный, если выполнен
`mkcert -install`; иначе принять предупреждение).

Что не сработало — чинить отдельными коммитами с тестом, затем пункт заново.

- [ ] **Шаг 3: документы**

- Спека: раздел «Что проверено» — числа задачи 1, итог `CACHE_VERSION`, результаты
  живой проверки по пунктам, модель iPhone и версия iOS; в «Разведке» и «Для
  исполнителя» Caddy заменить на TLS самого сервера (`just phone`).
- `AGENTS.md`:
  - список документов: спека и этот план;
  - карта кода: `touch.gd`, `touch_device.gd`, `code_field.gd`, `room_link.gd` в таблице
    платформы; `ui_input.gd`, `stage_layout.gd`, `touch_controls.gd`, `rotate_hint.gd` в
    таблице экранов; `tools/phone.sh`;
  - «грабли» — то, на что наступили в задачах 1, 7, 8, 9, и как минимум: iOS открывает
    клавиатуру только для поля, сфокусированного в самом касании, — отсюда своё поле;
    `VirtualJoystick` рисуется сам, пока ему не дали пустые стили; признак сенсорного
    устройства — `pointer: coarse`, не user agent; service worker и `CACHE_VERSION`.
- `README.md`: в строку про платформы — игра с телефона в браузере, горизонтально,
  установка на домашний экран.

- [ ] **Шаг 4: весь прогон и коммит**

```bash
./tools/test.sh
git add docs AGENTS.md README.md
git commit -m "docs: playing from a phone — what was checked, the code map and the rakes"
```

- [ ] **Шаг 5: отчёт пользователю**

Итог прогона `./tools/test.sh`, что проверено на телефоне и что нет, список коммитов.
MR — только по отдельному подтверждению.

## Локальная проверка отдачи, 2026-10-03

Исходник — `tools/haptics-check.html`; скопировать в `build/web/haptics-check.html`,
который раздаёт `just phone`. Страница не входит в экспорт игры, после пересборки её
может понадобиться скопировать снова. Ни библиотек, ни запросов на сторонние сайты.

В проверочной странице `change.isTrusted` не отличает программный `.click()` от
настоящего касания: браузер сам создаёт доверенный `change`. Для подписи причины
берётся `click.isTrusted`. Проверено настоящими касаниями в отдельном Chrome через CDP.

Браузерный тест `tools/test_haptics_check.mjs` принимает адрес CDP WebSocket отдельного
браузера и URL страницы. Запуск: `node tools/test_haptics_check.mjs <CDP-WS> <URL>`.
Проверяет касания двух независимых переключателей, вызов через скрипт, отсутствие
Vibration API и запрос короткого импульса. Это дополнительная ручная команда для
диагностической страницы; аппаратную отдачу и поведение WebKit на iPhone она не доказывает.

Результат живой проверки пользователя: Safari и Chrome на iPhone ведут себя одинаково.
Системный переключатель (пункт 1) и переключатель поверх FIRE (пункт 2) дают отдачу
при отпускании короткого тапа. Если зажать и подержать, отдача уже не срабатывает.
Пользователь отметил работающими только эти два пункта. Это не отдача в момент нажатия,
а для удерживаемых стрелок и FIRE её нет; рекомендация исполнителя — не переносить
этот способ в игровое управление. 2026-10-04 пользователь решил пока оставить анимацию без вибрации.

## Живая сеть и диагностика FIRE — 2026-10-05

После просьбы открыть NETWORK → QUICK GAME пользователь подтвердил, что два
пользователя играют вместе с телефона и компьютера. Одновременно сообщил об ощущении
пропусков стрельбы: при частых отдельных нажатиях анимация FIRE есть, а выстрела нет.

Отдельный локальный диагностический стенд провёл реальные события касаний через
вьюпорт Godot и существующий PressFeed: 200 коротких тапов дошли до NetInput (100 без
стрелки, 100 при удержании стрелки); удержание FIRE читалось во всех 60 снятиях LocalInput.
Повторное снятие не повторяет отпущенный тап. На пустом поле с неизменённым ядром оба
последовательных тапа дают IN_FIRE, но только первый создаёт пулю; после её исчезновения
новый тап снова создаёт пулю. Ограничение уже защищено test_one_bullet_at_a_time_without_stars.

После предложения проверить редкие тапы после исчезновения своей пули и удержание
FIRE пользователь подтвердил: «да, ок, работает». Проверка FIRE завершена. Код ввода и
ядро не менялись; полный ./tools/test.sh после диагностики зелёный: 628 тестов GUT, Go,
изоляция и ресурсы.

## Поле ввода кода под ROOM CODE — 2026-10-05

Пользователь не получил клавиатуру на JOIN ROOM и подтвердил причину: было непонятно,
куда нажать. CodeField создавал настоящее поле у верха страницы (top:12px), а экран
рисовал код отдельно под ROOM CODE. Касание этого рисунка попадало в canvas.

Сначала tools/test_code_field.mjs воспроизвёл ошибку в настоящей веб-сборке: в центре
видимого кода elementFromPoint возвращал canvas, а не room-code-field. После исправления
нативное поле занимает прямоугольник кода под ROOM CODE; дублирующего рисунка нет.
Пустое поле содержит TAP HERE, ниже — TAP TO TYPE. Размеры переводятся из вьюпорта в
CSS-прямоугольник canvas; поле перемещается при повороте и изменении размеров.

Полный ./tools/test.sh зелёный: 628/628 GUT, Go, изоляция и ресурсы; веб-экспорт содержит
35 уровней. Браузерная проверка зелёная: настоящее касание даёт фокус, короткий код не
отправляется, полный отправляется, изменение ширины, сокращение высоты и поворот с
плотностью 3 сохраняют фокус и положение, выход убирает поле. Запуск:
node tools/test_code_field.mjs <CDP-WS> <URL>. Клавиатуру iOS проверяет пользователь:
автоматизация доказывает фокус поля, а не появление клавиатуры на физическом телефоне.


## Проверка NO SUCH ROOM — 2026-10-05

Пользователь получил NO SUCH ROOM после ввода кода. Сервер и вкладка создателя комнаты
продолжали работать; в серверном журнале комната FR2EVA была открыта и не опустела.
Контрольный вход во втором изолированном Chrome: мобильная раскладка, NETWORK → JOIN ROOM,
пустое настоящее поле, касание, ввод FR2EVA через клавиатурные события и Enter. В исходящем
WebSocket-приветствии код FR2EVA, game=tanks; ответ сервера ok=true, slot=1. Оба браузера
начали и завершили уровень на одном tick=2778. Код ввода и сервера не менялся.

Это не воспроизводит ошибку на iPhone и не закрывает живую проверку. У пользователя
запрошены адрес игры и отображаемый код. Контрольный игрок закрыт; создана новая комната
для телефона. Следующая проверка — ссылка с заполненным кодом и FIRE, чтобы отделить
ручной набор от соединения; затем повторить ручной ввод. Последний полный тест остаётся
зелёным: 628/628 GUT, Go, изоляция и ресурсы.
