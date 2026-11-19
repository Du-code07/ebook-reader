import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../widgets/app_colors.dart';
import '../widgets/push_aside_route.dart';
import 'lock_screen.dart';

typedef PrivacyTr = String Function(String ko, String en, String zh, String ja);

/// 설정 → 일반 → 사생활 보호: 앱 잠금·모든 파일 잠금, 잠금 방식(비밀번호·패턴), 생체 인식
class PrivacyLockScreen extends StatefulWidget {
  const PrivacyLockScreen({super.key, required this.t});
  final PrivacyTr t;

  @override
  State<PrivacyLockScreen> createState() => _PrivacyLockScreenState();
}

class _PrivacyLockScreenState extends State<PrivacyLockScreen> {
  int _bioStatus = 0;

  String _t(String ko, String en, String zh, String ja) => widget.t(ko, en, zh, ja);

  @override
  void initState() {
    super.initState();
    AppLock.biometricStatus().then((s) {
      if (mounted) setState(() => _bioStatus = s);
    });
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Route<bool> _route(Widget page) => PushAsideRoute<bool>(builder: (_) => page);

  /// 지금 잠금을 한 번 확인 (끄거나 바꾸기 전에)
  Future<bool> _confirmCurrent() async {
    if (!AppLock.hasSecret) return true;
    final ok = await Navigator.of(context).push<bool>(_route(LockScreen(
      asRoute: true,
      title: _t('지금 잠금을 확인해 주세요', 'Confirm your current lock', '请验证当前锁定', '現在のロックを確認してください'),
      onCheck: () {},
    )));
    return ok == true;
  }

  /// 아직 정한 잠금이 없으면 지금 방식으로 정함
  Future<bool> _ensureSecret() async {
    if (AppLock.hasSecret) return true;
    final ok = await Navigator.of(context).push<bool>(_route(LockSetupPage(kind: AppLock.method.value)));
    return ok == true;
  }

  Future<void> _toggle(bool on, Future<void> Function(bool) set) async {
    if (on ? !await _ensureSecret() : !await _confirmCurrent()) return;
    await set(on);
    if (mounted) setState(() {});
  }

  Future<void> _pickMethod(String kind) async {
    if (kind == AppLock.method.value) return;
    if (!AppLock.hasSecret) {
      setState(() => AppLock.method.value = kind);
      return;
    }
    // 방식을 바꾸면 그 방식으로 새로 정함 (지금 잠금을 먼저 확인)
    if (!await _confirmCurrent() || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(_route(LockSetupPage(kind: kind)));
    if (ok == true && mounted) {
      setState(() {});
      _say(kind == 'pin'
          ? _t('비밀번호로 잠가요', 'Now locked with a PIN', '已改为密码锁定', '暗証番号でロックします')
          : _t('패턴으로 잠가요', 'Now locked with a pattern', '已改为图案锁定', 'パターンでロックします'));
    }
  }

  Future<void> _change() async {
    if (!await _confirmCurrent() || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(_route(LockSetupPage(kind: AppLock.method.value)));
    if (ok == true && mounted) {
      setState(() {});
      _say(_t('바꿨어요', 'Changed', '已更改', '変更しました'));
    }
  }

  Future<void> _toggleBio(bool on) async {
    if (on) {
      final s = await AppLock.biometricStatus();
      if (!mounted) return;
      setState(() => _bioStatus = s);
      if (s != 1) {
        _say(s == 2
            ? _t('휴대폰에 등록된 지문·얼굴이 없어요', 'No fingerprint or face is registered on this phone', '手机上没有登记指纹或面部', 'スマホに登録された指紋・顔がありません')
            : _t('이 기기에서는 생체 인식을 쓸 수 없어요', 'Biometrics are not available on this device', '此设备不支持生物识别', 'この端末では生体認証を使えません'));
        return;
      }
      if (!await _ensureSecret()) return;
      // 켜기 전에 한 번 해 봄
      if (!await AppLock.biometricAuth()) return;
    } else if (!await _confirmCurrent()) {
      return;
    }
    await AppLock.setBiometric(on);
    if (mounted) setState(() {});
  }

  Widget _card(String title, List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    // 카드 안 줄을 누르면 물결이 카드 위에 보이게 Material로 감쌈
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _switchRow({required String title, required String sub, required bool value, required ValueChanged<bool> onChanged, Widget? leading}) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: leading,
      title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      subtitle: Text(sub, style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }

  Widget _methodChip(String kind, String label, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    final bool on = AppLock.method.value == kind;
    final shadows = AppColors.sigShadows(context);
    return Expanded(
      child: Material(
        color: on ? AppColors.of(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _pickMethod(kind),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            // 아이콘을 글자 앞에 (고른 쪽도 같은 아이콘을 흰색으로)
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 18, color: on ? Colors.white : cs.onSurfaceVariant, shadows: on ? shadows : null),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on ? Colors.white : cs.onSurface, shadows: on ? shadows : null)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool pin = AppLock.method.value == 'pin';
    return Scaffold(
      appBar: AppBar(title: Text(_t('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          children: [
            _card(_t('잠금 적용 범위', 'What to lock', '锁定范围', 'ロックの範囲'), [
              _switchRow(
                title: _t('앱 실행 시 잠금', 'Lock when opening the app', '打开应用时锁定', 'アプリ起動時にロック'),
                sub: _t('앱을 열 때 잠금을 확인해요', 'Asks to unlock when you open the app', '打开应用时需要解锁', 'アプリを開くときにロックを確認します'),
                value: AppLock.appLock.value,
                onChanged: (v) => _toggle(v, AppLock.setAppLock),
              ),
              Divider(height: 1, indent: 16, endIndent: 16, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _switchRow(
                title: _t('모든 파일 잠금', 'Lock all files', '锁定所有文件', 'すべてのファイルをロック'),
                sub: _t('파일을 열 때 잠금을 확인해요\n파일 자체의 비밀번호와는 따로예요', 'Asks to unlock when you open a file\nSeparate from a file\'s own password', '打开文件时需要解锁\n与文件自身的密码无关', 'ファイルを開くときにロックを確認します\nファイル自体のパスワードとは別です'),
                value: AppLock.fileLock.value,
                onChanged: (v) => _toggle(v, AppLock.setFileLock),
              ),
            ]),
            _card(_t('잠금 방식 선택', 'Lock type', '锁定方式', 'ロック方式'), [
              Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(18)),
                child: Row(children: [
                  _methodChip('pin', _t('비밀번호', 'PIN', '密码', '暗証番号'), Icons.dialpad_rounded),
                  _methodChip('pattern', _t('패턴', 'Pattern', '图案', 'パターン'), Icons.apps_rounded),
                ]),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  AppLock.hasSecret
                      ? (pin ? _t('비밀번호 변경', 'Change PIN', '更改密码', '暗証番号を変更') : _t('패턴 변경', 'Change pattern', '更改图案', 'パターンを変更'))
                      : (pin ? _t('비밀번호 정하기', 'Set a PIN', '设置密码', '暗証番号を設定') : _t('패턴 정하기', 'Set a pattern', '设置图案', 'パターンを設定')),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                onTap: () async {
                  if (AppLock.hasSecret) {
                    await _change();
                  } else if (await _ensureSecret() && mounted) {
                    setState(() {});
                  }
                },
              ),
            ]),
            _card(_t('간편 인증', 'Quick unlock', '快捷验证', '簡単認証'), [
              _switchRow(
                leading: Icon(Icons.fingerprint, size: 34, color: cs.onSurface),
                title: _t('생체 인식 사용', 'Use biometrics', '使用生物识别', '生体認証を使う'),
                sub: _bioStatus == 0
                    ? _t('이 기기에서는 쓸 수 없어요', 'Not available on this device', '此设备不可用', 'この端末では使えません')
                    : _t('휴대폰에 등록된 지문·얼굴 인식으로 바로 풀어요', 'Unlock right away with the fingerprint or face registered on your phone', '用手机上登记的指纹·面部直接解锁', 'スマホに登録された指紋・顔認証ですぐに解除します'),
                value: AppLock.biometric.value,
                onChanged: _toggleBio,
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
              child: Text(
                _t('앱을 나갔다가 1분이 지나면 다시 잠겨요\n비밀번호·패턴을 잊으면 앱 설정의 데이터 지우기나 휴대폰 설정에서 앱 데이터를 지워야 해요\n잠금은 이리ERI 화면에서 보는 것만 막고, 파일 자체를 암호화하지는 않아요',
                    'It locks again when you are away from the app for over a minute\nIf you forget the PIN or pattern, you must clear the app data\nThe lock only protects viewing in 이리ERI; it does not encrypt the files themselves',
                    '离开应用超过 1 分钟后会再次锁定\n忘记密码或图案时需要清除应用数据\n锁定只限制在 이리ERI 中查看，不会加密文件本身',
                    'アプリを離れて1分が過ぎると再びロックされます\n暗証番号・パターンを忘れたらアプリのデータを削除する必要があります\nロックは이리ERIでの閲覧だけを制限し、ファイル自体は暗号化しません'),
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
