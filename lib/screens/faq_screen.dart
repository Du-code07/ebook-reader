import 'package:flutter/material.dart';

import '../services/pro.dart';
import '../services/storage_service.dart';
import '../widgets/push_aside_route.dart';
import 'contact_screen.dart';

/// 도움말 > 자주 묻는 질문: 질문을 누르면 답이 펼쳐짐 (맨 아래에 문의하기)
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key, required this.lang});
  final String lang;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String t(String ko, String en, String zh, String ja) => AppI18n.t(lang, ko: ko, en: en, zh: zh, ja: ja);

    final List<(String, String)> items = [
      (
        t('어떤 파일을 열 수 있나요?', 'Which files can I open?', '可以打开哪些文件？', 'どんなファイルを開けますか？'),
        t('PDF, EPUB, TXT, CBZ(만화), 워드(DOCX·DOC), 한글(HWP·HWPX), 파워포인트(PPTX·PPT), 엑셀(XLSX·XLSM·XLS)을 열 수 있어요. 사진은 이미지 합치기로 CBZ 파일로 만들어 볼 수 있어요',
            'PDF, EPUB, TXT, CBZ (comics), Word (DOCX, DOC), Hangul (HWP, HWPX), PowerPoint (PPTX, PPT) and Excel (XLSX, XLSM, XLS). Photos can be viewed by turning them into a CBZ file with Merge Images',
            '可以打开 PDF、EPUB、TXT、CBZ（漫画）、Word（DOCX、DOC）、韩文（HWP、HWPX）、PowerPoint（PPTX、PPT）和 Excel（XLSX、XLSM、XLS）。照片可以用"合并图片"做成 CBZ 文件后查看',
            'PDF、EPUB、TXT、CBZ（漫画）、Word（DOCX・DOC）、ハングル（HWP・HWPX）、PowerPoint（PPTX・PPT）、Excel（XLSX・XLSM・XLS）を開けます。写真は「画像結合」でCBZファイルにして見られます'),
      ),
      (
        t('무료 앱인가요?', 'Is the app free?', '这是免费应用吗？', '無料アプリですか？'),
        t('광고 없는 무료 앱이에요. 파일 보기, 메모, 북마크 같은 기본 기능은 모두 무료로 쓸 수 있어요',
            'Yes, it is a free app with no ads. Basic features such as viewing files, notes and bookmarks are all free',
            '这是没有广告的免费应用。查看文件、笔记、书签等基本功能都可以免费使用',
            '広告のない無料アプリです。ファイルの閲覧、メモ、ブックマークなどの基本機能はすべて無料で使えます'),
      ),
      (
        t('유료는 어떤 기능이 있나요?', 'What are the paid features?', '有哪些付费功能？', '有料機能には何がありますか？'),
        t('현재는 문서 스캔, 이미지 합치기, PDF 합치기가 있어요. 추후 업데이트를 통해 기능이 추가될 수 있어요. 그리고 이리ERI 프로를 사면 개발자에게 밥 한 끼 사 주는 셈이에요!',
            'Currently there are Scan Document, Merge Images and Merge PDFs. More features may be added in future updates. And buying 이리ERI Pro is like treating the developer to a meal!',
            '目前有扫描文档、合并图片和合并 PDF。今后可能会通过更新增加功能。另外，购买 이리ERI 专业版就相当于请开发者吃一顿饭！',
            '現在は文書スキャン、画像結合、PDF結合があります。今後のアップデートで機能が追加されることがあります。それに、이리ERI プロを買うと開発者にごはんを一食おごることにもなります！'),
      ),
      // 무료 제공 기간(2027년 3월 1일 전)에만
      if (Pro.freePeriod)
        (
          t('지금 유료 기능을 쓰려면 돈을 내야 하나요?', 'Do I have to pay to use the paid features now?', '现在使用付费功能需要付款吗？', '今、有料機能を使うのにお金がかかりますか？'),
          t('아니요. 2027년 3월 1일까지는 모든 유료 기능을 무료로 쓸 수 있어요. 그 뒤에는 이리ERI 프로(1회 구매)로 판매할 예정이고, 판매를 시작하기 전에 앱 안에서 미리 알려 드려요',
              'No. You can use all paid features free until March 1, 2027. After that, they are planned to be sold as 이리ERI Pro (a one-time purchase), and you will be notified in the app before sales begin',
              '不需要。2027年3月1日前可免费使用全部付费功能。之后计划以 이리ERI 专业版（一次性购买）出售，开始出售前会在应用内提前通知',
              'いいえ。2027年3月1日までは有料機能をすべて無料で使えます。その後は이리ERI プロ（買い切り）として販売する予定で、販売開始前にアプリ内でお知らせします'),
        ),
      (
        t('파일은 어떻게 추가되나요?', 'How are files added?', '文件是如何添加的？', 'ファイルはどのように追加されますか？'),
        t('파일을 추가하면 원본은 그대로 두고 앱 안에 사본을 저장해요. 그래서 원본을 옮기거나 지워도 서재에서 계속 볼 수 있어요. 파일 추가, 파일 탐색(등록한 폴더에서 찾기), 다른 앱의 공유·열기로 추가할 수 있어요',
            'When you add a file, the original is left as it is and a copy is saved inside the app, so you can keep reading it in the library even if you move or delete the original. You can add files with Add Files, Find Files (searching your registered folders), or Share/Open from another app',
            '添加文件时，原文件保持不变，应用会在内部保存一份副本，所以即使移动或删除原文件，也能在书架中继续阅读。可以通过"添加文件"、"查找文件"（在已登记的文件夹中查找）或从其他应用分享·打开来添加',
            'ファイルを追加すると、元のファイルはそのままにアプリ内にコピーを保存します。そのため元のファイルを移動・削除しても本棚で読み続けられます。ファイル追加、ファイル検索（登録したフォルダから探す）、他のアプリからの共有・開くで追加できます'),
      ),
      (
        t('파일 탐색은 왜 폴더를 등록해야 하나요?', 'Why do I need to register folders for Find Files?', '为什么"查找文件"需要登记文件夹？', 'ファイル検索でフォルダを登録するのはなぜですか？'),
        t('개인정보 보호를 위해 기기 전체를 뒤지지 않고, 직접 고른 폴더 안에서만 파일을 찾아요. 앱 설정 > 탐색할 폴더에서 넣고 뺄 수 있어요',
            'To protect your privacy, the app does not search the whole device but only the folders you choose. You can add or remove them in App Settings > Folders to Search',
            '为了保护隐私，应用不会搜索整个设备，只在你选择的文件夹中查找文件。可以在 应用设置 > 要查找的文件夹 中添加或移除',
            'プライバシー保護のため、端末全体は探さず、選んだフォルダの中だけでファイルを探します。アプリ設定 > 検索するフォルダ で追加・削除できます'),
      ),
      (
        t('메모나 북마크가 원본 파일을 바꾸나요?', 'Do notes or bookmarks change the original file?', '笔记或书签会修改原文件吗？', 'メモやブックマークで元のファイルは変わりますか？'),
        t('아니요. 메모와 북마크는 앱 안에 따로 저장돼서 원본 파일은 바뀌지 않아요. 스캔과 합치기도 원본을 바꾸지 않고 새 파일을 만들어요',
            'No. Notes and bookmarks are stored separately in the app and do not change the original file. Scanning and merging also create new files without changing the originals',
            '不会。笔记和书签单独保存在应用中，不会修改原文件。扫描和合并也会生成新文件，不会修改原文件',
            'いいえ。メモとブックマークはアプリ内に別に保存されるため、元のファイルは変わりません。スキャンや結合も元のファイルを変えずに新しいファイルを作ります'),
      ),
      (
        t('문서가 원래 프로그램과 다르게 보여요', 'Documents look different from the original program', '文档看起来和原程序不一样', '文書が元のプログラムと違って見えます'),
        t('문서를 기기 안에서 변환해 보여 주기 때문에 글꼴·서식·배치가 조금 다를 수 있어요. 앱 설정 > 글꼴에서 문서에 쓰인 글꼴 파일을 넣으면 더 비슷하게 보일 수 있어요',
            'Because documents are converted on your device, fonts, formatting and layout may look slightly different. Adding the font files used in the document under App Settings > Fonts can make them look closer to the original',
            '由于文档在设备上转换后显示，字体、格式和排版可能略有不同。在 应用设置 > 字体 中添加文档使用的字体文件，可以显示得更接近原样',
            '文書を端末内で変換して表示するため、フォント・書式・レイアウトが少し異なる場合があります。アプリ設定 > フォント で文書に使われたフォントファイルを追加すると、より近く表示できます'),
      ),
      (
        t('인터넷이 필요한가요?', 'Do I need an internet connection?', '需要联网吗？', 'インターネットは必要ですか？'),
        t('파일을 보는 데는 인터넷이 필요 없어요. 일부 Google 기능에만 인터넷이 쓰여요',
            'No internet is needed to view files. The internet is used only for some Google features',
            '查看文件不需要联网。只有部分 Google 功能会使用网络',
            'ファイルを見るのにインターネットは不要です。一部の Google 機能にだけ使われます'),
      ),
      (
        t('내 문서가 서버로 전송되나요?', 'Are my documents sent to a server?', '我的文档会被传到服务器吗？', '文書がサーバーに送られますか？'),
        t('아니요. 문서는 기기 안에서만 처리되고 운영자 서버로 보내지 않아요. 자세한 내용은 도움말 > 개인정보 처리방침에 있어요',
            'No. Documents are processed only on your device and are not sent to the operator\'s server. See Help > Privacy Policy for details',
            '不会。文档只在设备上处理，不会发送到运营者的服务器。详情请见 帮助 > 隐私政策',
            'いいえ。文書は端末内だけで処理され、運営者のサーバーには送られません。詳しくは ヘルプ > プライバシーポリシー をご覧ください'),
      ),
      (
        t('휴대폰을 바꾸면 서재가 옮겨지나요?', 'Is my library moved when I change phones?', '换手机后书架会转移吗？', '機種変更すると本棚は移りますか？'),
        t('서재와 메모는 기기 안에 저장돼서 기기 백업 설정에 따라 일부만 옮겨지거나 옮겨지지 않을 수 있어요. 중요한 파일은 공유 기능으로 따로 보관해 주세요',
            'Your library and notes are stored on the device, so depending on your device backup settings they may be moved only partly or not at all. Please keep important files separately with the Share feature',
            '书架和笔记保存在设备上，根据设备的备份设置，可能只转移一部分或无法转移。重要文件请用分享功能另行保存',
            '本棚とメモは端末内に保存されるため、端末のバックアップ設定によっては一部しか移らない、または移らないことがあります。大切なファイルは共有機能で別に保管してください'),
      ),
      (
        t('잠금 비밀번호를 잊었어요', 'I forgot my lock password', '忘记了锁定密码', 'ロックのパスワードを忘れました'),
        t('비밀번호와 패턴은 복구할 수 없어서, 앱 데이터를 지워야 잠금이 풀려요. 이때 서재·메모·북마크·설정이 모두 지워져요',
            'Passwords and patterns cannot be recovered, so the lock can only be removed by clearing the app data. This deletes your library, notes, bookmarks and settings',
            '密码和图案无法找回，只能清除应用数据来解除锁定。这样会删除书架、笔记、书签和设置',
            'パスワードとパターンは復元できないため、アプリのデータを消さないとロックは解除できません。このとき本棚・メモ・ブックマーク・設定がすべて消えます'),
      ),
      (
        t('데이터 지우기를 하면 무엇이 지워지나요?', 'What does Clear Data delete?', '清除数据会删除什么？', 'データ消去で何が消えますか？'),
        t('앱 안의 파일 사본, 합치기·스캔으로 만든 PDF, 메모, 북마크, 설정이 지워져요. Download 등 원래 폴더에 있는 원본 파일은 지워지지 않아요',
            'File copies in the app, PDFs created by merging or scanning, notes, bookmarks and settings are deleted. Original files in folders such as Download are not deleted',
            '会删除应用内的文件副本、通过合并或扫描生成的 PDF、笔记、书签和设置。Download 等原文件夹中的原文件不会被删除',
            'アプリ内のファイルのコピー、結合・スキャンで作ったPDF、メモ、ブックマーク、設定が消えます。Download などのフォルダにある元のファイルは消えません'),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(t('자주 묻는 질문', 'FAQ', '常见问题', 'よくある質問'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            for (final (q, a) in items)
              Theme(
                // 펼침 칸의 위아래 선 없애기
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  // 짧은 대답도 가운데가 아니라 왼쪽부터
                  expandedAlignment: Alignment.centerLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: Text(q, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                  children: [
                    // 대답은 모든 줄을 질문보다 조금 안쪽에서 시작 (두 번째 줄부터도 같은 자리)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(a, style: TextStyle(fontSize: 14.5, height: 1.55, color: cs.onSurface.withValues(alpha: 0.86))),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Center(
              child: Text(t('원하는 답이 없나요?', 'Didn\'t find your answer?', '没有找到答案？', '答えが見つかりませんか？'),
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(height: 8),
            Center(
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).push(PushAsideRoute(builder: (_) => ContactScreen(lang: lang))),
                icon: const Icon(Icons.mail_outline),
                label: Text(t('문의하기', 'Contact Us', '联系我们', 'お問い合わせ')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
