# Поэтапный план архитектуры и доработки MaterialDrop (Flutter)

Документ составлен по результатам анализа:
- текущего Flutter-проекта (`c:\test\material_drop_flutter`),
- предыдущей ПК-реализации (`c:\test\material_drop` — локальные модули `app.py`, `main_window.py`, `material_hud.py`, `overlay_app.py`, `backend/clipboard_helper.py`, `backend/game_detector.py`; история `.git` в старом каталоге отсутствует).

**Принципы реализации:**
- Ноль заглушек (`TODO`, `pass`, фиктивных моков) и ноль Python-кода.
- Каждый модуль и платформенный канал доводится до полностью рабочего состояния перед переходом к следующему этапу.
- Соблюдаются требования по памяти (оптимизированные текстуры, потоковый I/O, изоляция GPU-шейдеров через `RepaintBoundary`).

---

## Текущее состояние vs Требования ТЗ (резюме анализа)

| Область | Что уже есть в `material_drop_flutter` | Что потеряно из `material_drop` / нужно добавить |
|---|---|---|
| **UI и Адаптив** | `HomeShell` (`NavigationBar` / `NavigationRail`), двухпанельный радар в `SendScreen`, MD3-темы | Чёткий брейкпоинт `< 600dp` vs `>= 840dp` Supporting Pane Layout (слева — радар + DropZone, справа — очередь, прогресс, история и быстрые настройки), hover + ПКМ-меню, компактная `VisualDensity` на ПК |
| **Десктоп (Win 11 + Linux/Hyprland)** | `desktop_drop` для файлов, `audioplayers`, иконка `.ico`, заголовок окна | Нет `linux/` платформы (`flutter create`), закрытие окна завершает процесс (`SetQuitOnClose(true)`), нет System Tray, нет нативных уведомлений, нет папок в Drag-and-Drop, нет отправки по `Ctrl+V` (включая `CF_DIB` изображения и файлы), нет CLI-мультиинстанса (`--port`, `--bind`, `--name`) |
| **Сеть (`TransportEngine`)** | `MaterialDropDiscovery`/HTTP (`45872–45874`) и Dart-реализация Quick Share | Не унифицирован в единый `TransportEngine` с автопереключением; отсутствует протокол **LocalSend v2** (+ HTTPS с проверкой `fingerprint`); нет **BLE + NFC HCE + WifiP2p/LocalOnlyHotspot**; нет **Iroh** (P2P QUIC по интернету); нет Rust **`rquickshare_core`** на ПК и нативного `ACTION_SEND` Quick Share на Android |
| **Анимации** | `SwipeableFileCard` с `SpringSimulation`, `SonarRadar` | Нет пре-события `drop_gesture_trigger` (WebSocket, 20% свайпа, доминантный цвет + 32×32 превью); нет безрамочного десктопного **Dynamic Island / Floating HUD** (как в `material_hud.py`/`overlay_app.py`, включая `gtk-layer-shell` на Hyprland и настройку позиции сверху/снизу) и нет GPU **`FragmentShader` (Liquid Glass)** |
| **OTA и CI/CD** | Базовый `.github/workflows/build.yml` (APK + Windows ZIP) | Нет `UpdateService` (проверка GitHub Releases, SHA256, нативное обновление `.apk` / `windows-x64.zip` / `.AppImage`); нет `.github/workflows/release.yml` для сборки `android-arm64.apk`, `windows-x64.zip`, `linux-x64.AppImage`, `checksums.txt` по тегу `v*` |

---

## Этап 1. Адаптивный Desktop/Mobile UI и десктопная инфраструктура (Windows 11 + Linux/Hyprland)

**Цель:** подготовить платформенный фундамент для Windows 11, Linux (включая Wayland/Hyprland) и Android, восстановить потерянные функции ПК-клиента и привести раскладку к канонам MD3.

### Задачи этапа
1. **Инициализация Linux-платформы и CLI-мультиинстанса:**
   - Добавить поддержку `linux/` (`flutter create --platforms=linux .`), настроить CMake-сборку и метаданные приложения (`MaterialDrop`).
   - Пробросить аргументы командной строки из `windows/runner/main.cpp` и `linux/runner/my_application.cc` в `main(List<String> args)`.
   - Реализовать парсер CLI-флагов (`--port`, `--bind`, `--name`, `--tray`) и изолированное хранилище настроек/портов при указании `--name` / `--bind` (для запуска 2+ копий ПК ↔ ПК на `127.0.0.1` и `127.0.0.2`).
   - Разрешить сокетам переиспользование адресов (`SO_REUSEADDR` / `SO_REUSEPORT` там, где поддерживается ОС) и `multicastLoopback = true` (для отладки на одной машине).
2. **System Tray, фоновый режим и нативные уведомления:**
   - Windows (Win32 C++ в `runner/` + платформенный канал): перехват `WM_CLOSE` (сворачивание в трей при закрытии окна), нативная иконка `Shell_NotifyIconW` в трее, контекстное меню трея (Открыть, Отправить файл, Папка загрузок, Автоприём, Звуки, Выход), восстановление окна по клику ЛКМ и нативные Windows balloon/toast уведомления при фоновом приёме.
   - Linux: поддержка StatusNotifierItem (`libayatana-appindicator3` / `tray_manager`) и `libnotify` уведомлений.
   - Проверка полноэкранного режима / игр на Windows (`SHQueryUserNotificationState`, перенос логики из `backend/game_detector.py` на Win32 C++).
3. **Drag-and-Drop (файлы и папки) и быстрая отправка по `Ctrl+V`:**
   - Расширить модель `StagedFile` полем `relativePath` (для сохранения структуры каталогов) и добавить рекурсивный обход перетащенных папок в `SendScreen`.
   - Реализовать обработчик `Shortcuts`/`CallbackShortcuts` для `Ctrl+V` / `Ctrl+Shift+V` на Windows и Linux: чтение из системного буфера обмена файлов (`CF_HDROP` / `text/uri-list`), изображений (`CF_DIB` / `image/png` через Win32 API / Wayland `wl-paste`) и текста/ссылок с мгновенным открытием радара отправки.
   - Заменить вызов PowerShell при копировании принятых картинок в буфер обмена на нативный Win32 Clipboard API (`CF_DIB`) в C++.
4. **Адаптивный UI (MD3 Canonical Layouts):**
   - `< 600dp` (Mobile): нижний `NavigationBar`, вертикальная одноколоночная навигация.
   - `>= 840dp` (Desktop / Tablet): боковой `NavigationRail` / раскрываемый `NavigationDrawer` + **Supporting Pane Layout**:
     - Левая панель: радар устройств + большая интерактивная Drop-зона (файлы/папки) + кнопки выбора и вставки `Ctrl+V`.
     - Правая панель: активная очередь отправки и прогресс, история передач и быстрые настройки (папка сохранения, автоприём, имя и порт устройства).
   - Компактная плотность (`VisualDensity.compact`) на десктопе, hover-подсветка и контекстное меню по ПКМ.

**Критерий готовности этапа 1:** запуск двух независимых инстансов на Windows (`--bind 127.0.0.1 --name PC-1 --port 53317` и `--bind 127.0.0.2 --name PC-2 --port 53318`), передача папки перетаскиванием и картинки через `Ctrl+V`, сворачивание в трей и фоновый приём с нативным уведомлением.

---

## Этап 2. Единый `TransportEngine` и `LanTransport` (LocalSend v2)

**Цель:** спроектировать расширяемую архитектуру `TransportEngine` без привязки к одному протоколу и реализовать базовый LAN-канал (полная совместимость с LocalSend v2).

### Задачи этапа
1. **Абстракция `TransportEngine` и маршрутизатор каналов (`TransportRouter`):**
   - Определить общий интерфейс: `TransportChannel` (`id`, `priority`, `isAvailable`, `start()`, `stop()`, `startDiscovery()`, `stopDiscovery()`, `sendOffer()`, `acceptOffer()`, `declineOffer()`, `cancelTransfer()`, потоки `devicesStream` и `eventsStream`).
   - Единая модель `DiscoveredPeer` с поддержкой нескольких транспортов на одно устройство (автопереключение по приоритету: `LAN → TapProximity → InternetP2P`).
2. **`LanTransport` (полная совместимость с протоколом LocalSend v2 + HTTPS TLS):**
   - UDP Multicast discovery на `224.0.0.167:53317` (с учётом `--bind`, `SO_REUSEADDR`, `IP_MULTICAST_LOOP`) + HTTP fallback.
   - Полная реализация LocalSend v2 HTTP/HTTPS API:
     - `POST /api/localsend/v2/register` / `GET /api/localsend/v2/info`
     - `POST /api/localsend/v2/prepare-upload` (сессионные токены, подтверждение пользователем, автоприём, сохранение структуры `relativePath` папок)
     - `POST /api/localsend/v2/upload?sessionId=...&fileId=...&token=...` (потоковая передача без загрузки в RAM)
     - `POST /api/localsend/v2/cancel`
   - Генерация самоподписанного X.509/TLS-сертификата устройства и вычисление его SHA-256 `fingerprint`.
   - Явная обработка самоподписанных сертификатов пиров в `HttpClient.badCertificateCallback`: сравнение SHA-256 отпечатка предъявленного `X509Certificate` с заявленным `fingerprint` пира из LocalSend discovery / session (отклонение при несовпадении).

**Критерий готовности этапа 2:** успешная двусторонняя передача файлов и папок по HTTPS/HTTP с реальным клиентом LocalSend (Windows/Android/iOS) с валидацией TLS `fingerprint`.

---

## Этап 3. `TapProximityTransport`: BLE Advertising + NFC HCE + Wi-Fi Direct / LocalOnlyHotspot

**Цель:** реализовать автономную передачу без роутера, интернета и обход гостевых сетей с AP Isolation (аналог NameDrop + AirDrop AWDL).

### Задачи этапа
1. **Разрешения и Foreground Service для Android 13–14+ (`AndroidManifest.xml`):**
   - Добавить `<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />` (для `LocalOnlyHotspot` / `WifiP2p`), а также BLE/NFC разрешения (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `NFC`).
   - Настроить сервис `TransferForegroundService`: `android:foregroundServiceType="connectedDevice|dataSync"` и runtime-запрос всех нужных разрешений до запуска BLE/P2P, чтобы избежать `SecurityException`.
2. **BLE Discovery и оценка близости (`RSSI`):**
   - Компактный BLE Advertising пакет (`Service UUID` MaterialDrop + 16-байтный ротируемый каждые 15 минут `ephemeral_id` + маска возможностей/транспорта).
   - На Android: `BluetoothLeAdvertiser` + `BluetoothLeScanner` в Kotlin (`BleProximityManager.kt`), сглаживание `RSSI` (Kalman / EMA фильтр) для отображения близости на радаре («Вплотную / Рядом»).
   - На Windows/Linux: поддержка WinRT Bluetooth LE (`Windows.Devices.Bluetooth.Advertisement`) / BlueZ D-Bus (при наличии BLE-адаптера; честное отображение статуса адаптера, если в ПК нет Bluetooth).
3. **NFC Tap-to-Share (Android ↔ Android):**
   - Реализация `HostApduService` (`MaterialDropApduService.kt`) в режиме HCE (приём APDU SELECT AID + обмен компактным CBOR/JSON-пакетом: эфемерный ECDH-публичный ключ P-256, имя устройства, параметры прямого Wi-Fi / P2P / Iroh-тикет).
   - Активация `NfcAdapter.enableReaderMode` при открытом окне отправки, чтобы касание двух Android-смартфонов мгновенно инициировало рукопожатие без выбора в списке.
4. **Прямой Wi-Fi канал без роутера (Android):**
   - Реализация в `WifiDirectManager.kt`:
     - Инициация группы через `WifiP2pManager` (Wi-Fi Direct) или `WifiManager.startLocalOnlyHotspot` (получение временных SSID + WPA2 пароля + IP шлюза).
     - Подключение клиента на Android 10+ через `WifiNetworkSpecifier.Builder()` + `ConnectivityManager.requestNetwork(...)` с точечной привязкой сокетов через `connectivityManager.bindProcessToNetwork(network)` (чтобы **не разрывать** мобильный интернет).
   - После поднятия прямого линка поверх него автоматически запускается передача через `LanTransport` с шифрованием ключом, согласованным по NFC/BLE.

**Критерий готовности этапа 3:** при выключенном Wi-Fi-роутере (или в сети с AP Isolation) два Android-устройства находят друг друга по BLE/касанию NFC, без `SecurityException` поднимают прямой канал (`LocalOnlyHotspot` / `WifiP2p`) и передают файл, не теряя мобильный интернет.

---

## Этап 4. `InternetP2PTransport` (Iroh QUIC P2P) + нативный Quick Share (`rquickshare_core` на ПК и Google Play Services на Android)

**Цель:** обеспечить передачу через интернет без своего сервера (P2P + публичные релеи) и полноценный нативный Quick Share на всех платформах.

*(Техническое требование: чистый Rust-крейт без зависимостей Tauri; для dev-профиля отключён тяжёлый LTO во избежание перерасхода RAM и диска; основная кросс-компиляция выносится в CI).*

### Задачи этапа
1. **Единый чистый Rust FFI-крейт (`native/materialdrop_rust`):**
   - Настроить `Cargo.toml` без зависимостей Tauri и с облегчённым dev-профилем (`lto = false`, `opt-level = 1` в dev; полная оптимизация в CI), C-ABI интерфейс через `flutter_rust_bridge` или чистый `dart:ffi`.
   - Обёртка над **`iroh`** (QUIC P2P транспорт, сквозной TLS 1.3, NAT hole-punching, автоматический fallback на публичные Iroh-релеи):
     - генерация `NodeId` и `NodeTicket` (обмен тикетом только через ссылку `materialdrop://iroh/...`, NFC или BLE),
     - потоковый приём и отправка файлов и директорий по `iroh` BLOB/stream протоколу с колбэками прогресса и отмены.
   - Обёртка над чистым крейтом **`rquickshare_core`** (без Tauri) для Windows и Linux:
     - нативный mDNS + UKEY2 + приём/отправка файлов с любыми Android/Windows устройствами в локальной сети.
2. **Android Quick Share (системная интеграция):**
   - Переключение режима Quick Share в настройках; явная кнопка **«Отправить через системный Quick Share»** на экране отправки, запускающая `Intent.ACTION_SEND` / `Intent.ACTION_SEND_MULTIPLE` с таргетингом в системный модуль Quick Share (`com.google.android.gms` / системный Chooser с исключением компонентов самого MaterialDrop).
3. **Интеграция в `TransportEngine`:**
   - Регистрация custom URL scheme / deep link `materialdrop://iroh/...` (Android `intent-filter`, Windows/Linux protocol handler) и автоматический выбор канала `InternetP2PTransport` (Iroh) при передаче тикета через ссылку, NFC или BLE.

**Критерий готовности этапа 4:** передача файла с ПК/телефона в другой сети через мобильный интернет по ссылке `materialdrop://iroh/...` (или через NFC/BLE обмен тикетом) без собственного VPS; приём и отправка на Windows/Linux со штатным Android Quick Share через `rquickshare_core`.

---

## Этап 5. Swipe-to-Shoot, WebSocket Pre-Gesture Trigger и Desktop Dynamic Island + GPU Liquid Glass Shader

**Цель:** реализовать фирменную сквозную анимацию взаимодействия «свайп на телефоне → мгновенный вылет жидкого стекла на приёмнике» с 60–120 FPS.

### Задачи этапа
1. **Пре-событие жеста (`drop_gesture_trigger`) по WebSocket:**
   - Добавить лёгкий WebSocket/HTTP-upgrade канал поверх активного транспорта (`ws://<peer>:<port>/ws/gesture`).
   - В `SwipeableFileCard`: отслеживать прогресс свайпа вверх; при достижении порога **20% (`dragProgress >= 0.20`)** однократно вызывать `HapticFeedback.heavyImpact()` и немедленно отправлять JSON-кадр `drop_gesture_trigger`:
     - метаданные файла(ов) (имя, размер, тип, количество),
     - **доминантный цвет** превью (быстрый 8×8/16×16 даунсэмпл в Dart/Isolate без фризов UI),
     - **32×32 сжатое превью** (base64 JPEG/WEBP для картинок/видео).
   - При отмене свайпа (палец отпущен до броска) — отправка `drop_gesture_cancel`, чтобы оверлей у приёмника плавно спрятался обратно.
2. **GPU-шейдер `Liquid Glass` (`shaders/liquid_glass.frag`):**
   - Написать GLSL Fragment Shader для Flutter (`FragmentProgram.fromAsset('shaders/liquid_glass.frag')`):
     - хроматическая/пространственная рефракция краёв капсулы на базе signed distance field (SDF rounded rect),
     - спекулярный блик по контуру с привязкой к доминантному цвету превью файла и фазе анимации,
     - без полноэкранного `BackdropFilter`.
   - Использовать `RepaintBoundary` вокруг карточки оверлея для кэширования текстур в состоянии покоя и снижения нагрузки на Intel UHD / бюджетные GPU.
3. **Безрамочный плавающий оверлей (Desktop Dynamic Island + настройка позиции):**
   - На **Windows (Win32)**: безрамочное прозрачное окно поверх всех окон (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW`, без иконки в панели задач), выезжающее с «желейной» пружинной физикой (`SpringSimulation`).
   - На **Linux / Wayland (Hyprland)**: обязательное использование **`gtk-layer-shell` (`wlr-layer-shell`)** (`GTK_LAYER_SHELL_LAYER_OVERLAY` + привязка к верхнему/нижнему краю экрана), чтобы композитор не тайлил оверлей как обычное окно.
   - **Настраиваемая позиция острова** в Настройках (`topCenter` — сверху по центру или `bottomCenter` — снизу по центру, как в старой ПК-версии), с сохранением в `SharedPreferences`.
   - На **Android**: внутриприложенческий/оверлейный желейный баннер сверху/снизу при открытом приложении и head-up уведомление в фоне.
   - Состояния острова: `pre_gesture_peek` (вытягивание «капли» с 32×32 превью в момент свайпа) → `offer` (Принять / Отклонить / PIN) → `progress` → `completed` (Копировать в буфер / Открыть / Показать в папке) → автоскрытие.

**Критерий готовности этапа 5:** при начале свайпа файла вверх на телефоне на 20% высоты на экране Windows/Linux в выбранной позиции (сверху или снизу по центру, без тайлинга в Hyprland за счёт `gtk-layer-shell`) плавно вытягивается «остров» из жидкого стекла с цветом и 32×32 миниатюрой файла ещё до завершения броска; стабильные 60+ FPS без `BackdropFilter`.

---

## Этап 6. OTA-обновления (`UpdateService`) и CI/CD (`release.yml`)

**Цель:** настроить полностью автоматическую сборку и публикацию релизов на GitHub и самообновление приложения на Android, Windows и Linux.

### Задачи этапа
1. **`UpdateService` в приложении:**
   - Периодическая и ручная проверка `https://api.github.com/repos/kiryattf/MaterialDrop/releases/latest` с локальным кэшированием (ETag / timestamp в `SharedPreferences`), сравнением semver (`vX.Y.Z`) с версией из `pubspec.yaml`.
   - Настройки → блок «Обновления» и MD3-диалог / плашка с отрендеренным changelog из release body.
   - Скачивание `checksums.txt` и платформенного архива/пакета с прогресс-баром + строгой проверкой **SHA256** перед запуском установки:
     - **Android:** скачивание `android-arm64.apk` в кэш и запуск системного установщика `Intent.ACTION_VIEW` через `FileProvider` (с разрешением `REQUEST_INSTALL_PACKAGES`).
     - **Windows:** скачивание полного портативного **`windows-x64.zip`** бандла (`material_drop.exe` + все `.dll` + папка `data/`), распаковка во временную директорию, запуск временного `.cmd`/PowerShell апдейтера после корректного закрытия `material_drop.exe` для полной замены бандла целиком и перезапуска новой версии (исключает рассинхрон DLL и ассетов).
     - **Linux:** скачивание нового `.AppImage`, установка флага исполнения (`chmod +x`) и атомарная замена текущего бинарника через `File.rename` / POSIX `rename(2)`.
2. **Release CI/CD (`.github/workflows/release.yml`):**
   - Триггер на пуш git-тега `v*` (и `workflow_dispatch`).
   - Сборка нативных Rust-библиотек (`iroh` + `rquickshare_core`, без Tauri) и Flutter для трёх платформ:
     - `ubuntu-latest`: прогон `flutter analyze` + `flutter test` + Rust-тестов; сборка `android-arm64.apk` (`flutter build apk --release --target-platform android-arm64`).
     - `windows-latest`: сборка Rust DLL + `flutter build windows --release` → упаковка полного портативного бандла `windows-x64.zip` (`material_drop.exe` + все `.dll` + `data/`).
     - `ubuntu-latest`: установка `libgtk-layer-shell-dev` и зависимостей трея, сборка Rust `.so` + `flutter build linux --release` + упаковка в `linux-x64.AppImage` (`appimagetool`).
   - Генерация `checksums.txt` (`sha256sum`) и публикация всех 4 файлов в **GitHub Releases** через `softprops/action-gh-release`.

**Критерий готовности этапа 6:** при пуше тега `v2.1.0` GitHub Actions без ошибок собирает `android-arm64.apk`, `windows-x64.zip`, `linux-x64.AppImage` и `checksums.txt` в GitHub Release, а `UpdateService` находит новый релиз, проверяет SHA256 и безопасно обновляет полный бандл/пакет на каждой платформе.

---

## Примечания по зависимостям и окружению перед стартом

1. Для **Этапа 4** (Rust `iroh` + `rquickshare_core`) потребуется установленный **Rust (`rustup`)** (включается в CI-скриптах автоматически; dev-профиль без LTO для экономии RAM/диска).
2. Для тестирования **Этапа 3** (NFC HCE, BLE Advertising, `WifiP2p`/`LocalOnlyHotspot` + `NEARBY_WIFI_DEVICES`) потребуется два физических Android-устройства с NFC/BLE и сборка APK.
3. Для тестирования **Этапа 1–2 и 5 (Linux / Hyprland + `gtk-layer-shell`)** сборка `AppImage` выполняется через GitHub Actions `ubuntu-latest`.

**План подтверждён с правками — перехожу к реализации Этапа 1.**
