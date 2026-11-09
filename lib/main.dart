// =============================================================================
//  iPad JEAL
//  Hub de servicios web ligeros para iPad con iOS 12.5.8 (chip A7, 1 GB RAM).
//
//  Estrategia de "bypass":
//   1. User-Agent de Android de gama baja  -> los servidores envian versiones Lite.
//   2. Proxy de Google Translate (opcional) -> Google renderiza y simplifica el
//      HTML para que el WebKit de iOS 12 pueda mostrarlo.
//   3. YouTube via Invidious               -> interfaz sin JavaScript pesado y
//      video MP4 progresivo (360p) que iOS 12 reproduce de forma nativa.
//
//  Compilar SIEMPRE en modo release o profile en el dispositivo real:
//      flutter run --release
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Con 1 GB de RAM el WebView necesita toda la memoria posible:
  // reducimos la cache de imagenes de Flutter (por defecto 100 MB).
  PaintingBinding.instance.imageCache
    ..maximumSize = 40
    ..maximumSizeBytes = 16 << 20; // 16 MB

  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const IpadJealApp());
}

// =============================================================================
//  PALETA / TEMA
// =============================================================================

class JealColors {
  JealColors._();

  static const Color black = Color(0xFF000000);
  static const Color surface = Color(0xFF0A0B0E);
  static const Color surfaceHigh = Color(0xFF14161B);
  static const Color white = Color(0xFFFFFFFF);
  static const Color text = Color(0xFFF5F7FA);
  static const Color muted = Color(0xFF8E96A3);
  static const Color line = Color(0x33FFFFFF);

  static const Color green = Color(0xFF00E676);
  static const Color blue = Color(0xFF2979FF);
  static const Color cyan = Color(0xFF00B8FF);
  static const Color danger = Color(0xFFFF5252);

  static const LinearGradient brand = LinearGradient(
    colors: [green, cyan, blue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Sombra "neon". Se usa con moderacion: cada blur cuesta GPU en un A7.
  static List<BoxShadow> glow(Color c, {double blur = 16, int alpha = 0x66}) =>
      [BoxShadow(color: c.withAlpha(alpha), blurRadius: blur, spreadRadius: 1)];
}

ThemeData buildJealTheme() {
  const scheme = ColorScheme.dark(
    primary: JealColors.green,
    secondary: JealColors.blue,
    surface: JealColors.surface,
    onPrimary: JealColors.black,
    onSecondary: JealColors.white,
    onSurface: JealColors.text,
    error: JealColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: JealColors.black,
    canvasColor: JealColors.black,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: JealColors.black,
      foregroundColor: JealColors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: JealColors.surfaceHigh,
      contentTextStyle: TextStyle(color: JealColors.white, fontSize: 15),
      behavior: SnackBarBehavior.floating,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? JealColors.white
            : JealColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? JealColors.green
            : JealColors.surfaceHigh,
      ),
    ),
  );
}

// =============================================================================
//  CONFIGURACION GLOBAL
// =============================================================================

/// Perfiles de identidad del navegador (suplantacion de User-Agent).
enum UaProfile {
  androidLite(
    'Android Lite',
    'Chrome antiguo en Android de gama baja (recomendado)',
    'Mozilla/5.0 (Linux; Android 7.0; SM-J330F) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/71.0.3578.99 Mobile Safari/537.36',
  ),
  kaiOs(
    'KaiOS ultraligero',
    'Teléfono básico: páginas mínimas, casi sin JavaScript',
    'Mozilla/5.0 (Mobile; Nokia 8110 4G; rv:48.0) Gecko/48.0 '
        'Firefox/48.0 KAIOS/2.5',
  ),
  ipadNative(
    'iPad nativo',
    'Safari iOS 12 real (por si un sitio falla con los otros)',
    'Mozilla/5.0 (iPad; CPU OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1',
  );

  const UaProfile(this.label, this.description, this.userAgent);
  final String label;
  final String description;
  final String userAgent;
}

/// Instancias publicas de Invidious. Cambian con el tiempo: revisa
/// https://docs.invidious.io/instances/ y actualiza esta lista si alguna cae.
const List<String> kInvidiousInstances = [
  'https://inv.nadeko.net',
  'https://yewtu.be',
  'https://invidious.nerdvpn.de',
];

class AppState {
  AppState._();

  static final ValueNotifier<bool> proxyEnabled = ValueNotifier<bool>(false);
  static final ValueNotifier<UaProfile> uaProfile =
      ValueNotifier<UaProfile>(UaProfile.androidLite);
  static final ValueNotifier<String> invidious =
      ValueNotifier<String>(kInvidiousInstances.first);
}

// =============================================================================
//  UTILIDADES DE URL / PROXY
// =============================================================================

class UrlTools {
  UrlTools._();

  static const String translatePrefix =
      'https://translate.google.com/translate?sl=auto&tl=es&u=';

  /// Hosts que nunca deben envolverse en el proxy (evita bucles de login).
  static const Set<String> _exemptHosts = {
    'accounts.google.com',
    'consent.google.com',
    'consent.youtube.com',
  };

  /// Convierte texto libre en URL: dominio -> https://, texto -> busqueda.
  static String? normalize(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return text;
    }
    final looksLikeDomain = !text.contains(' ') && text.contains('.');
    if (looksLikeDomain) return 'https://$text';
    // DuckDuckGo Lite: buscador sin JavaScript, perfecto para iOS 12.
    return 'https://lite.duckduckgo.com/lite/?q=${Uri.encodeQueryComponent(text)}';
  }

  static bool isProxied(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'translate.google.com' ||
        host.endsWith('.translate.goog') ||
        host.endsWith('translate.googleusercontent.com');
  }

  static bool isExempt(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return _exemptHosts.contains(host);
  }

  /// Envuelve una URL en el proxy de Google Translate (-> español).
  static String wrap(String url) {
    if (isProxied(url)) return url;
    return '$translatePrefix${Uri.encodeComponent(url)}';
  }

  /// Recupera la URL original desde una URL del proxy.
  ///   translate.google.com/translate?u=X            -> X
  ///   www-example-com.translate.goog/path?_x_tr_... -> www.example.com/path
  static String unwrap(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    if (uri.host == 'translate.google.com') {
      return uri.queryParameters['u'] ?? url;
    }

    const suffix = '.translate.goog';
    if (uri.host.endsWith(suffix)) {
      final encoded = uri.host.substring(0, uri.host.length - suffix.length);
      // Codificacion de Google: '-' = '.', '--' = '-'
      final host = encoded
          .replaceAll('--', '\u0000')
          .replaceAll('-', '.')
          .replaceAll('\u0000', '-');
      final params = Map<String, List<String>>.from(uri.queryParametersAll)
        ..removeWhere((k, _) => k.startsWith('_x_tr_'));
      return Uri(
        scheme: 'https',
        host: host,
        path: uri.path,
        queryParameters: params.isEmpty ? null : params,
        fragment: uri.fragment.isEmpty ? null : uri.fragment,
      ).toString();
    }
    return url;
  }

  static bool isInvidious(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return false;
    return kInvidiousInstances.any((i) => Uri.parse(i).host == host) ||
        Uri.parse(AppState.invidious.value).host == host;
  }

  /// En paginas /watch de Invidious fuerza:
  ///   quality=medium -> MP4 progresivo 360p (iOS 12 lo reproduce nativamente,
  ///                     sin DASH ni MediaSource).
  ///   local=true     -> el video se sirve a traves de la instancia.
  static String optimizeInvidious(String url) {
    if (!isInvidious(url)) return url;
    final uri = Uri.parse(url);
    if (uri.path != '/watch' || uri.queryParameters.containsKey('quality')) {
      return url;
    }
    final params = Map<String, String>.from(uri.queryParameters)
      ..['quality'] = 'medium'
      ..['local'] = 'true';
    return uri.replace(queryParameters: params).toString();
  }
}

// =============================================================================
//  APP
// =============================================================================

class IpadJealApp extends StatelessWidget {
  const IpadJealApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iPad JEAL',
      debugShowCheckedModeBanner: false,
      theme: buildJealTheme(),
      home: const DashboardScreen(),
    );
  }
}

// =============================================================================
//  DASHBOARD
// =============================================================================

class _Service {
  const _Service({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.url,
    this.bypassProxy = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final String Function() url;

  /// YouTube/Invidious va directo: ya es ultraligero y el proxy de
  /// traduccion rompe la reproduccion de video. Manten pulsado para forzarlo.
  final bool bypassProxy;
}

final List<_Service> _services = [
  _Service(
    title: 'YouTube',
    subtitle: 'Vía Invidious · sin JavaScript pesado',
    icon: Icons.play_circle_fill_rounded,
    accent: JealColors.green,
    url: () => '${AppState.invidious.value}/',
    bypassProxy: true,
  ),
  _Service(
    title: 'Facebook',
    subtitle: 'Versión móvil ligera',
    icon: Icons.facebook_rounded,
    accent: JealColors.blue,
    url: () => 'https://m.facebook.com/',
  ),
  _Service(
    title: 'Instagram',
    subtitle: 'Web móvil',
    icon: Icons.camera_alt_rounded,
    accent: JealColors.cyan,
    url: () => 'https://www.instagram.com/',
  ),
  _Service(
    title: 'Navegador libre',
    subtitle: 'Búsqueda ligera y cualquier sitio',
    icon: Icons.public_rounded,
    accent: JealColors.green,
    url: () => 'https://lite.duckduckgo.com/lite/',
  ),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TextEditingController _urlCtrl = TextEditingController();
  final FocusNode _urlFocus = FocusNode();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _open(String url, {bool bypassProxy = false, bool forceProxy = false}) {
    _urlFocus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(
          initialUrl: url,
          bypassProxy: bypassProxy,
          forceProxy: forceProxy,
        ),
      ),
    );
  }

  void _submitAddress(String text) {
    final url = UrlTools.normalize(text);
    if (url != null) _open(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 24,
        title: const _BrandTitle(),
        actions: [
          const ProxyToggle(),
          const SizedBox(width: 8),
          _GlowIconButton(
            icon: Icons.tune_rounded,
            tooltip: 'Ajustes',
            onPressed: () => showJealSettings(context),
          ),
          const SizedBox(width: 20),
        ],
        bottom: const _GlowDivider(),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _DashboardHeader(),
              const SizedBox(height: 20),
              AddressField(
                controller: _urlCtrl,
                focusNode: _urlFocus,
                hint: 'Escribe una dirección o lo que quieras buscar…',
                onSubmitted: _submitAddress,
                large: true,
              ),
              const SizedBox(height: 24),
              Expanded(child: _buildGrid()),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Consejo: mantén pulsado un botón para abrirlo a través del proxy de traducción.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: JealColors.muted, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    const spacing = 20.0;
    return LayoutBuilder(
      builder: (context, c) {
        final tileW = (c.maxWidth - spacing) / 2;
        var tileH = (c.maxHeight - spacing) / 2;
        // Con el teclado abierto el espacio se reduce: permitimos scroll.
        final scroll = tileH < 150;
        if (scroll) tileH = 150;
        return GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: tileW / tileH,
          physics: scroll
              ? const BouncingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          children: [
            for (final s in _services)
              _ServiceTile(
                service: s,
                onTap: () => _open(s.url(), bypassProxy: s.bypassProxy),
                onLongPress: () => _open(s.url(), forceProxy: true),
              ),
          ],
        );
      },
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: JealColors.brand,
            borderRadius: BorderRadius.circular(12),
            boxShadow: JealColors.glow(JealColors.green, blur: 14),
          ),
          child: const Text(
            'J',
            style: TextStyle(
              color: JealColors.black,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 14),
        const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'iPad JEAL',
              style: TextStyle(
                color: JealColors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'Service Hub',
              style: TextStyle(
                color: JealColors.green,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppState.proxyEnabled, AppState.uaProfile]),
      builder: (context, _) {
        final proxy = AppState.proxyEnabled.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Centro de servicios',
              style: TextStyle(
                color: JealColors.white,
                fontSize: 32,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _StatusChip(
                  icon: Icons.fingerprint_rounded,
                  label: 'Identidad: ${AppState.uaProfile.value.label}',
                  color: JealColors.blue,
                ),
                _StatusChip(
                  icon: Icons.translate_rounded,
                  label: proxy ? 'Proxy de traducción: ACTIVO' : 'Conexión directa',
                  color: proxy ? JealColors.green : JealColors.muted,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(0x99)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: JealColors.text, fontSize: 13)),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    super.key,
    required this.service,
    required this.onTap,
    required this.onLongPress,
  });

  final _Service service;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final accent = service.accent;
    final radius = BorderRadius.circular(26);
    return Container(
      decoration: BoxDecoration(
        color: JealColors.surface,
        borderRadius: radius,
        border: Border.all(color: accent, width: 2),
        boxShadow: JealColors.glow(accent, blur: 22, alpha: 0x55),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          splashColor: accent.withAlpha(0x33),
          highlightColor: accent.withAlpha(0x1A),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: FittedBox(
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: JealColors.brand,
                        boxShadow: JealColors.glow(accent, blur: 18),
                      ),
                      child: Icon(service.icon, size: 50, color: JealColors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  service.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JealColors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  service.subtitle,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JealColors.muted, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  COMPONENTES COMPARTIDOS
// =============================================================================

/// Interruptor global del proxy de Google Translate.
class ProxyToggle extends StatelessWidget {
  const ProxyToggle({super.key, this.onChanged, this.compact = false});

  final ValueChanged<bool>? onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.proxyEnabled,
      builder: (context, on, _) {
        return Container(
          padding: const EdgeInsets.only(left: 14, right: 4),
          decoration: BoxDecoration(
            color: JealColors.surface,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: on ? JealColors.green : JealColors.line,
              width: 1.5,
            ),
            boxShadow: on ? JealColors.glow(JealColors.green, blur: 12) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.translate_rounded,
                size: 20,
                color: on ? JealColors.green : JealColors.muted,
              ),
              if (!compact) ...[
                const SizedBox(width: 8),
                Text(
                  on ? 'Proxy ES' : 'Directo',
                  style: TextStyle(
                    color: on ? JealColors.white : JealColors.muted,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ],
              Switch(
                value: on,
                onChanged: (v) {
                  AppState.proxyEnabled.value = v;
                  onChanged?.call(v);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Barra de direcciones blanca (alto contraste sobre el fondo negro).
class AddressField extends StatelessWidget {
  const AddressField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.hint = 'Buscar o escribir dirección',
    this.large = false,
    this.secure = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final String hint;
  final bool large;
  final bool secure;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(large ? 18 : 14);
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: large ? JealColors.glow(JealColors.blue, blur: 18) : null,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onSubmitted: onSubmitted,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(
          color: JealColors.black,
          fontSize: large ? 19 : 16,
          fontWeight: FontWeight.w500,
        ),
        cursorColor: JealColors.blue,
        decoration: InputDecoration(
          isDense: !large,
          filled: true,
          fillColor: JealColors.white,
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF7A808A)),
          prefixIcon: Icon(
            secure ? Icons.lock_rounded : Icons.search_rounded,
            color: secure ? const Color(0xFF00A152) : JealColors.blue,
          ),
          suffixIcon: IconButton(
            icon: const Icon(Icons.arrow_forward_rounded, color: JealColors.blue),
            onPressed: () => onSubmitted(controller.text),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: large ? 20 : 12,
          ),
          border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: const BorderSide(color: JealColors.green, width: 2.5),
          ),
        ),
      ),
    );
  }
}

class _GlowIconButton extends StatelessWidget {
  const _GlowIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color = JealColors.blue,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color color;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = enabled ? color : JealColors.line;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: JealColors.surface,
        shape: CircleBorder(side: BorderSide(color: c, width: 1.5)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: enabled ? JealColors.white : JealColors.muted, size: 26),
          ),
        ),
      ),
    );
  }
}

class _GlowDivider extends StatelessWidget implements PreferredSizeWidget {
  const _GlowDivider();

  @override
  Size get preferredSize => const Size.fromHeight(2);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        gradient: JealColors.brand,
        boxShadow: JealColors.glow(JealColors.cyan, blur: 10),
      ),
    );
  }
}

/// Hoja de ajustes: identidad del navegador e instancia de Invidious.
Future<void> showJealSettings(
  BuildContext context, {
  VoidCallback? onUserAgentChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: JealColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      side: BorderSide(color: JealColors.blue, width: 1.5),
    ),
    builder: (context) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([AppState.uaProfile, AppState.invidious]),
          builder: (context, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SheetTitle('Identidad del navegador (User-Agent)'),
                  for (final p in UaProfile.values)
                    RadioListTile<UaProfile>(
                      value: p,
                      groupValue: AppState.uaProfile.value,
                      activeColor: JealColors.green,
                      contentPadding: EdgeInsets.zero,
                      title: Text(p.label,
                          style: const TextStyle(
                              color: JealColors.white, fontWeight: FontWeight.w700)),
                      subtitle: Text(p.description,
                          style: const TextStyle(color: JealColors.muted)),
                      onChanged: (v) {
                        if (v == null) return;
                        AppState.uaProfile.value = v;
                        onUserAgentChanged?.call();
                      },
                    ),
                  const SizedBox(height: 16),
                  const _SheetTitle('Instancia de Invidious (YouTube)'),
                  for (final i in kInvidiousInstances)
                    RadioListTile<String>(
                      value: i,
                      groupValue: AppState.invidious.value,
                      activeColor: JealColors.green,
                      contentPadding: EdgeInsets.zero,
                      title: Text(Uri.parse(i).host,
                          style: const TextStyle(color: JealColors.white)),
                      onChanged: (v) {
                        if (v != null) AppState.invidious.value = v;
                      },
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Si YouTube no carga, prueba otra instancia: son servidores comunitarios.',
                    style: TextStyle(color: JealColors.muted, fontSize: 13),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: JealColors.green,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// =============================================================================
//  NAVEGADOR (MOTOR WEB + INYECTOR DE USER-AGENT + PROXY)
// =============================================================================

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    super.key,
    required this.initialUrl,
    this.bypassProxy = false,
    this.forceProxy = false,
  });

  final String initialUrl;

  /// Sesion directa aunque el proxy global este activo (Invidious).
  final bool bypassProxy;

  /// Forzar el proxy aunque el interruptor global este apagado.
  final bool forceProxy;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _web;
  final TextEditingController _addr = TextEditingController();
  final FocusNode _addrFocus = FocusNode();
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  late bool _bypass;
  late bool _forced;
  bool _canBack = false;
  bool _canForward = false;
  bool _secure = true;
  String? _error;
  int _crashReloads = 0;

  bool get _proxyActive => (_forced || AppState.proxyEnabled.value) && !_bypass;

  @override
  void initState() {
    super.initState();
    _forced = widget.forceProxy;
    _bypass = widget.bypassProxy && !widget.forceProxy;

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(JealColors.black)
      // ---- INYECTOR DE USER-AGENT -------------------------------------------
      ..setUserAgent(AppState.uaProfile.value.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => _progress.value = p / 100,
          onPageStarted: (url) {
            _showAddress(url);
            if (_error != null && mounted) setState(() => _error = null);
          },
          onPageFinished: (url) {
            _progress.value = 1;
            _crashReloads = 0;
            _showAddress(url);
            _refreshNavState();
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _showAddress(url);
          },
          onWebResourceError: _onWebError,
          onNavigationRequest: _onNavigationRequest,
        ),
      );

    _load(widget.initialUrl);
  }

  @override
  void dispose() {
    _addr.dispose();
    _addrFocus.dispose();
    _progress.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  Logica de proxy / reescritura de URLs
  // ---------------------------------------------------------------------------

  /// Devuelve la URL final que debe cargarse segun el estado del proxy.
  /// Es idempotente: _resolve(_resolve(x)) == _resolve(x)  (evita bucles).
  String _resolve(String url) {
    if (_proxyActive) {
      if (UrlTools.isProxied(url) || UrlTools.isExempt(url)) return url;
      return UrlTools.wrap(url);
    }
    return UrlTools.optimizeInvidious(url);
  }

  void _load(String url) {
    _web.loadRequest(Uri.parse(_resolve(url)));
  }

  /// Intercepta TODA navegacion del marco principal (clics, redirecciones,
  /// formularios) para que pase por el proxy cuando este activo.
  NavigationDecision _onNavigationRequest(NavigationRequest req) {
    if (!req.isMainFrame) return NavigationDecision.navigate;

    final uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.prevent;

    const passthrough = {'about', 'data', 'blob'};
    if (passthrough.contains(uri.scheme)) return NavigationDecision.navigate;

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      // intent://, fb://, itms-apps:// ... no existen o no funcionan en iOS 12.
      _toast('Enlace de aplicación externa bloqueado (${uri.scheme}:)');
      return NavigationDecision.prevent;
    }

    final target = _resolve(req.url);
    if (target != req.url) {
      _web.loadRequest(Uri.parse(target));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _onWebError(WebResourceError e) {
    // iOS mata el proceso de WebKit cuando se queda sin memoria (1 GB RAM).
    if (e.errorType == WebResourceErrorType.webContentProcessTerminated) {
      if (_crashReloads < 2) {
        _crashReloads++;
        _toast('La página usó demasiada memoria. Recargando…');
        _web.reload();
      } else if (mounted) {
        setState(() => _error =
            'Esta página consume más memoria de la que tiene el iPad.\n'
            'Prueba el proxy de traducción o la identidad "KaiOS ultraligero".');
      }
      return;
    }

    if (e.isForMainFrame == false) return;
    // -999 = cancelada, 102 = interrumpida por politica (nuestros redirects).
    if (e.errorCode == -999 || e.errorCode == 102) return;

    if (mounted) {
      _progress.value = 1;
      setState(() => _error = e.description.isEmpty
          ? 'No se pudo cargar la página (código ${e.errorCode}).'
          : e.description);
    }
  }

  // ---------------------------------------------------------------------------
  //  Acciones de UI
  // ---------------------------------------------------------------------------

  void _showAddress(String url) {
    if (!mounted) return;
    final original = UrlTools.unwrap(url);
    final secure = original.startsWith('https://');
    if (!_addrFocus.hasFocus) _addr.text = original;
    if (secure != _secure) setState(() => _secure = secure);
  }

  Future<void> _refreshNavState() async {
    final back = await _web.canGoBack();
    final fwd = await _web.canGoForward();
    if (mounted && (back != _canBack || fwd != _canForward)) {
      setState(() {
        _canBack = back;
        _canForward = fwd;
      });
    }
  }

  void _submitAddress(String text) {
    final url = UrlTools.normalize(text);
    if (url == null) return;
    _addrFocus.unfocus();
    // Una direccion nueva termina la sesion "directa" de Invidious.
    _bypass = false;
    _load(url);
  }

  Future<void> _onProxyToggled(bool on) async {
    _bypass = false;
    if (!on) _forced = false;
    final current = await _web.currentUrl() ?? widget.initialUrl;
    final original = UrlTools.unwrap(current);
    _web.loadRequest(Uri.parse(on ? UrlTools.wrap(original) : _resolve(original)));
    _toast(on ? 'Proxy de traducción activado' : 'Conexión directa');
  }

  Future<void> _openOriginal() async {
    final current = await _web.currentUrl();
    if (current == null) return;
    _bypass = true;
    _web.loadRequest(Uri.parse(UrlTools.optimizeInvidious(UrlTools.unwrap(current))));
  }

  Future<void> _retryViaProxy() async {
    final current = await _web.currentUrl() ?? widget.initialUrl;
    _bypass = false;
    _forced = true;
    setState(() => _error = null);
    _web.loadRequest(Uri.parse(UrlTools.wrap(UrlTools.unwrap(current))));
  }

  Future<void> _applyUserAgent() async {
    await _web.setUserAgent(AppState.uaProfile.value.userAgent);
    await _web.reload();
    _toast('Identidad: ${AppState.uaProfile.value.label}');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: JealColors.green),
        ),
      ));
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(),
            const _GlowDivider(),
            _buildProgress(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: WebViewWidget(controller: _web)),
                  if (_error != null) _buildErrorPanel(),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          _GlowIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Cerrar',
            color: JealColors.green,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AddressField(
              controller: _addr,
              focusNode: _addrFocus,
              onSubmitted: _submitAddress,
              secure: _secure,
            ),
          ),
          const SizedBox(width: 12),
          ProxyToggle(onChanged: _onProxyToggled),
          const SizedBox(width: 8),
          _GlowIconButton(
            icon: Icons.tune_rounded,
            tooltip: 'Ajustes',
            onPressed: () =>
                showJealSettings(context, onUserAgentChanged: _applyUserAgent),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return SizedBox(
      height: 3,
      child: ValueListenableBuilder<double>(
        valueListenable: _progress,
        builder: (context, p, _) {
          if (p >= 1) return const SizedBox.shrink();
          return LinearProgressIndicator(
            value: p == 0 ? null : p,
            minHeight: 3,
            color: JealColors.green,
            backgroundColor: Colors.transparent,
          );
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: JealColors.black,
        border: Border(top: BorderSide(color: JealColors.line)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 10, 24, 10 + MediaQuery.of(context).padding.bottom),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _GlowIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            tooltip: 'Atrás',
            enabled: _canBack,
            onPressed: () => _web.goBack(),
          ),
          _GlowIconButton(
            icon: Icons.arrow_forward_ios_rounded,
            tooltip: 'Adelante',
            enabled: _canForward,
            onPressed: () => _web.goForward(),
          ),
          _GlowIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Recargar',
            color: JealColors.green,
            onPressed: () {
              setState(() => _error = null);
              _web.reload();
            },
          ),
          _GlowIconButton(
            icon: Icons.open_in_browser_rounded,
            tooltip: 'Ver original (sin proxy)',
            color: JealColors.cyan,
            onPressed: _openOriginal,
          ),
          _GlowIconButton(
            icon: Icons.home_rounded,
            tooltip: 'Inicio',
            color: JealColors.green,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPanel() {
    return Positioned.fill(
      child: Container(
        color: JealColors.black,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: JealColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: JealColors.danger, width: 1.5),
            boxShadow: JealColors.glow(JealColors.danger, blur: 18, alpha: 0x44),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, color: JealColors.danger, size: 54),
              const SizedBox(height: 14),
              const Text(
                'No se pudo mostrar la página',
                style: TextStyle(
                  color: JealColors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _error ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(color: JealColors.muted, fontSize: 15),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  _PillButton(
                    label: 'Reintentar',
                    icon: Icons.refresh_rounded,
                    onPressed: () {
                      setState(() => _error = null);
                      _web.reload();
                    },
                  ),
                  if (!_proxyActive)
                    _PillButton(
                      label: 'Abrir vía proxy',
                      icon: Icons.translate_rounded,
                      filled: true,
                      onPressed: _retryViaProxy,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(30);
    return Container(
      decoration: BoxDecoration(
        gradient: filled ? JealColors.brand : null,
        borderRadius: radius,
        border: filled ? null : Border.all(color: JealColors.blue, width: 1.5),
        boxShadow: filled ? JealColors.glow(JealColors.green, blur: 14) : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: filled ? JealColors.black : JealColors.white),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: filled ? JealColors.black : JealColors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
