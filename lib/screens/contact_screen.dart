import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../widgets/push_aside_route.dart';
import 'legal_screen.dart';

/// 도움말 > 문의하기: 본인 이메일·제목·내용을 적고 [보내기]를 누르면
/// 메일 앱이 받는 사람·제목·내용이 채워진 채로 열림 (앱이 직접 메일 서버로 보내지는 않음)
class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key, required this.lang});
  final String lang;

  static const String supportEmail = 'dudu.dev.pr@gmail.com';

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  static const _ch = MethodChannel('ebook_reader/pdf_renderer');

  final _email = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  bool _withDeviceInfo = true;
  bool _tried = false;

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(widget.lang, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void dispose() {
    _email.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _emailOk => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());

  Future<void> _send() async {
    setState(() => _tried = true);
    if (!_emailOk || _subject.text.trim().isEmpty || _body.text.trim().isEmpty) return;
    final b = StringBuffer(_body.text.trim());
    b.write('\n\n---\n');
    b.write('${_t('본인 이메일', 'Your email', '您的邮箱', 'ご自身のメール')}: ${_email.text.trim()}\n');
    if (_withDeviceInfo) {
      try {
        final info = await _ch.invokeMapMethod<String, Object?>('deviceInfo');
        if (info != null) {
          b.write('이리ERI ${info['appVersion'] ?? ''} (${info['appBuild'] ?? ''})\n');
          b.write('${info['manufacturer'] ?? ''} ${info['model'] ?? ''} / Android ${info['android'] ?? ''}\n');
        }
      } catch (_) {}
    }
    bool opened = false;
    try {
      opened = await _ch.invokeMethod<bool>('sendEmail', {
            'to': ContactScreen.supportEmail,
            'subject': '[이리ERI] ${_subject.text.trim()}',
            'body': b.toString(),
          }) ??
          false;
    } catch (_) {}
    if (!mounted) return;
    if (opened) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_t('메일 앱에서 보내기를 눌러 주세요', 'Tap Send in your email app', '请在邮件应用中点击发送', 'メールアプリで送信を押してください'))));
    } else {
      await Clipboard.setData(ClipboardData(text: '${ContactScreen.supportEmail}\n\n${_subject.text.trim()}\n\n$b'));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t('메일 앱을 찾지 못했어요', 'No email app found', '未找到邮件应用', 'メールアプリが見つかりません')),
          content: Text(_t('문의 내용을 복사해 두었어요\n${ContactScreen.supportEmail}로 직접 보내 주세요',
              'Your message has been copied\nPlease send it to ${ContactScreen.supportEmail}',
              '已复制咨询内容\n请直接发送到 ${ContactScreen.supportEmail}', 'お問い合わせ内容をコピーしました\n${ContactScreen.supportEmail} に直接送ってください')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('확인', 'OK', '确定', 'OK')))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    InputDecoration deco(String label, {String? error, String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        );
    final String need = _t('적어 주세요', 'Required', '请填写', '入力してください');
    return Scaffold(
      appBar: AppBar(title: Text(_t('문의하기', 'Contact Us', '联系我们', 'お問い合わせ'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _tried ? setState(() {}) : null,
              decoration: deco(_t('본인 이메일', 'Your email', '您的邮箱', 'ご自身のメール'),
                  error: _tried && !_emailOk ? _t('이메일 주소를 확인해 주세요', 'Please check the email address', '请检查邮箱地址', 'メールアドレスを確認してください') : null),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _subject,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _tried ? setState(() {}) : null,
              decoration: deco(_t('제목', 'Subject', '标题', '件名'), error: _tried && _subject.text.trim().isEmpty ? need : null),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _body,
              minLines: 7,
              maxLines: 14,
              onChanged: (_) => _tried ? setState(() {}) : null,
              decoration: deco(_t('내용', 'Message', '内容', '内容'),
                  error: _tried && _body.text.trim().isEmpty ? need : null,
                  hint: _t('어떤 파일에서 어떤 문제가 생겼는지 적어 주시면 빨리 확인할 수 있어요', 'Telling us which file and what happened helps us check faster',
                      '写明是哪个文件出现了什么问题，可以更快确认', 'どのファイルで何が起きたかを書いていただくと早く確認できます')),
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _withDeviceInfo,
              onChanged: (v) => setState(() => _withDeviceInfo = v ?? true),
              title: Text(_t('앱 버전과 기기 정보 함께 보내기', 'Include app version and device info', '一并发送应用版本和设备信息', 'アプリのバージョンと端末情報も送る'),
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              subtitle: Text(_t('기기 모델, Android 버전', 'Device model, Android version', '设备型号、Android 版本', '端末モデル、Android バージョン'),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(height: 8),
            Text(
              _t('[보내기]를 누르면 내용이 채워진 메일 앱이 열려요. 메일 앱에서 한 번 더 보내기를 눌러 주세요\n보낸 정보는 개인정보 처리방침 7항에 따라 처리돼요',
                  'Tapping [Send] opens your email app with the message filled in. Tap Send once more in the email app\nThe information you send is handled according to Section 7 of the Privacy Policy',
                  '点击 [发送] 会打开已填好内容的邮件应用。请在邮件应用中再点一次发送\n发送的信息将按照隐私政策第 7 条处理',
                  '[送信]を押すと内容が入力されたメールアプリが開きます。メールアプリでもう一度送信を押してください\n送った情報はプライバシーポリシー第7項に従って扱われます'),
              style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => LegalScreen(doc: LegalDoc.privacy, lang: widget.lang))),
                child: Text(_t('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー'),
                    style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(_t('보내기', 'Send', '发送', '送信'), style: const TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
