# iPad JEAL — Configuración iOS 12.5.8 (iPad Air 1 / mini 2-3 · A7 · 1 GB)

## 0. Requisitos de compilación

| Elemento | Versión | Motivo |
|---|---|---|
| Flutter | **3.27.4** (Dart 3.6) | 3.35+ exige iOS 13; 3.29+ elimina Skia en iOS |
| Xcode | 15.x o 16.x (en macOS) | Ambos aceptan *deployment target* iOS 12.0 |
| webview_flutter_wkwebview | `< 3.23.0` | 3.23.1 eliminó el soporte para iOS < 13 |

> Compilar para iOS **requiere macOS** con Xcode (o un CI en la nube como Codemagic / GitHub Actions `macos-latest`). Desde Windows solo se puede editar el código.

```bash
# Dentro de esta carpeta (no sobrescribe lib/main.dart ni pubspec.yaml existentes)
flutter create --platforms=ios --org com.jeal --project-name ipad_jeal .
flutter pub get
```

## 1. `ios/Runner/Info.plist`

Añade estas claves dentro del `<dict>` principal:

```xml
<!-- Tráfico de red: permite HTTP y HTTPS con TLS antiguo (iOS 12) -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>

<!-- Vistas nativas embebidas (WKWebView). Requerido por versiones antiguas del
     motor; inofensivo en las nuevas. -->
<key>io.flutter.embedded_views_preview</key>
<true/>

<!-- Forzar Skia en lugar de Impeller: más estable y ligero en GPU A7.
     (Solo funciona hasta Flutter 3.27, por eso fijamos esa versión.) -->
<key>FLTEnableImpeller</key>
<false/>

<!-- Pantalla completa en iPad (evita Split View, que duplica uso de RAM) -->
<key>UIRequiresFullScreen</key>
<true/>
<key>UIStatusBarStyle</key>
<string>UIStatusBarStyleLightContent</string>
<key>UIViewControllerBasedStatusBarAppearance</key>
<false/>

<!-- Reproducción de vídeo en línea dentro del WebView (Invidious) -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>

<key>CFBundleDisplayName</key>
<string>iPad JEAL</string>
```

> `UIBackgroundModes/audio` es opcional: permite que el audio de un vídeo siga sonando con la pantalla bloqueada. Quítalo si no lo necesitas.

## 2. `ios/Podfile`

```ruby
platform :ios, '12.0'

# ... (contenido generado por Flutter) ...

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
    end
  end
end
```

## 3. `ios/Flutter/AppFrameworkInfo.plist`

```xml
<key>MinimumOSVersion</key>
<string>12.0</string>
```

## 4. Xcode

1. Abre `ios/Runner.xcworkspace`.
2. *Runner → General → Minimum Deployments* → **iOS 12.0**.
3. *Signing & Capabilities* → selecciona tu Apple ID (una cuenta gratuita firma por 7 días).
4. Dispositivo: solo **iPad** (`TARGETED_DEVICE_FAMILY = 2`).

## 5. Instalar en el iPad

```bash
cd ios && pod install && cd ..
flutter run --release        # NUNCA en debug: el modo JIT no cabe en 1 GB
```

## Notas de compatibilidad

- **Instagram** exige JavaScript moderno; puede fallar incluso con Android Lite. Pruébalo con el proxy (mantén pulsado el botón) o con la identidad "iPad nativo".
- **Facebook** retiró `mbasic.facebook.com` en 2024; se usa `m.facebook.com`.
- **Invidious**: las instancias públicas cambian. Actualiza `kInvidiousInstances` en `lib/main.dart` con https://docs.invidious.io/instances/. Los enlaces `/watch` se reescriben con `quality=medium&local=true` (MP4 360p progresivo, reproducible de forma nativa en iOS 12).
- **Proxy de Google Translate**: `translate.google.com/translate?u=` redirige a dominios `*.translate.goog`; la app los reconoce y muestra la URL original en la barra.

