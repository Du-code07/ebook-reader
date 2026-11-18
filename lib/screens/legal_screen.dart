import 'package:flutter/material.dart';

/// 도움말: 이용 약관 · 개인정보 처리방침 (지금은 한국어 초안 — 출시 전에 영어로 바꿀 예정)
/// 운영자 이름·문의 이메일·시행일은 아직 비워 둠
enum LegalDoc { terms, privacy }

/// 아직 정하지 않은 칸 (운영자·이메일·시행일)
const String _blank = '(비어 있음)';

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.doc});
  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (String title, List<(String, List<String>)> sections) = switch (doc) {
      LegalDoc.terms => ('이용 약관', _terms),
      LegalDoc.privacy => ('개인정보 처리방침', _privacy),
    };
    return Scaffold(
      appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
            children: [
              Text('시행일: $_blank', style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              for (final (head, paras) in sections) ...[
                const SizedBox(height: 18),
                Text(head, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                for (final p in paras)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.startsWith('- ')) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 9, right: 8, left: 2),
                            child: Container(width: 4, height: 4, decoration: BoxDecoration(color: cs.onSurfaceVariant, shape: BoxShape.circle)),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            p.startsWith('- ') ? p.substring(2) : p,
                            style: TextStyle(fontSize: 14.5, height: 1.55, color: cs.onSurface.withValues(alpha: 0.86)),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

const List<(String, List<String>)> _terms = [
  ('제1조 (목적)', [
    '이 약관은 FReader(이하 "앱")를 이용할 때 운영자와 이용자 사이의 권리·의무와 책임을 정해요',
  ]),
  ('제2조 (정의)', [
    '- "앱"은 운영자가 Google Play로 제공하는 문서 보기 앱 FReader를 말해요',
    '- "이용자"는 이 약관에 따라 앱을 쓰는 사람을 말해요',
    '- "유료 기능"은 Google Play 결제를 거쳐 따로 이용할 수 있는 기능을 말해요',
    '- "이용자 파일"은 이용자가 앱에 추가하거나 앱으로 연 문서·이미지 등의 파일과 이용자가 쓴 메모·북마크를 말해요',
  ]),
  ('제3조 (약관의 효력과 변경)', [
    '이 약관은 앱 안 도움말에 올려 두고, 이용자가 앱을 쓰면 효력이 생겨요',
    '운영자는 관련 법령을 어기지 않는 범위에서 약관을 바꿀 수 있고, 바꿀 때는 시행일과 바뀐 내용을 시행 7일 전부터 앱 안이나 Google Play 앱 페이지에 알려요 (이용자에게 불리한 변경은 30일 전부터)',
    '바뀐 약관에 동의하지 않으면 앱 이용을 멈추고 앱을 지울 수 있어요',
  ]),
  ('제4조 (서비스 내용)', [
    '앱은 PDF·한글(HWP·HWPX)·워드·파워포인트·엑셀·EPUB·TXT·이미지 파일을 기기 안에서 열어 보고, 메모·북마크·스캔·합치기 등의 기능을 제공해요',
    '기본 기능은 무료이고, 일부 기능은 유료 기능으로 제공해요',
    '앱은 문서를 기기 안에서 변환해 보여 주므로, 글꼴·서식·배치가 원본 프로그램에서 보는 것과 다르게 보일 수 있어요',
  ]),
  ('제5조 (유료 기능의 결제와 환불)', [
    '유료 기능의 가격·이용 기간 등은 구매 화면에 표시해요',
    '결제는 Google Play 결제 시스템으로 이루어지며, 결제 수단·영수증·결제 취소는 Google Play 정책을 따라요',
    '환불은 Google Play 환불 정책과 「전자상거래 등에서의 소비자보호에 관한 법률」 등 관련 법령에 따라 처리해요',
    '이미 사용을 시작한 디지털 콘텐츠처럼 법령상 청약 철회가 제한되는 경우에는 환불이 어려울 수 있고, 운영자는 이런 사실을 구매 전에 알려요',
    '운영자의 잘못으로 유료 기능을 쓸 수 없게 되면 관련 법령에 따라 환불이나 그에 맞는 조치를 해요',
  ]),
  ('제6조 (이용자 파일)', [
    '이용자 파일의 권리는 이용자 또는 원래 권리자에게 있어요',
    '앱은 이용자 파일을 운영자 서버로 보내거나 운영자가 볼 수 있게 저장하지 않아요',
    '이용자는 저작권 등 다른 사람의 권리를 침해하지 않는 범위에서 파일을 이용해야 해요',
    '이용자 파일과 메모는 이용자 기기에만 저장되므로, 기기 분실·앱 삭제·데이터 지우기로 사라질 수 있어요. 중요한 파일은 이용자가 따로 백업해 주세요',
  ]),
  ('제7조 (금지 행위)', [
    '- 앱을 역설계·분해하거나 고쳐서 다시 배포하는 행위 (관련 법령이나 오픈소스 라이선스가 허락하는 경우는 빼고)',
    '- 유료 기능을 정상 결제 없이 쓰려는 행위',
    '- 앱을 법령에 어긋나는 목적으로 쓰는 행위',
  ]),
  ('제8조 (서비스의 변경과 중단)', [
    '운영자는 앱 기능을 고치거나 바꿀 수 있고, 업데이트로 반영해요',
    '운영자 사정으로 앱 제공을 멈출 때는 미리 Google Play 앱 페이지나 앱 안에서 알리고, 이용 기간이 남은 유료 기능은 관련 법령에 따라 처리해요',
  ]),
  ('제9조 (책임의 제한)', [
    '운영자는 천재지변, 기기·운영체제 문제, 이용자 잘못 등 운영자에게 책임이 없는 사유로 생긴 손해에 대해 책임지지 않아요',
    '운영자는 문서가 원본과 다르게 보이거나 일부가 보이지 않는 것에 대해, 고의나 중대한 과실이 없으면 책임지지 않아요',
    '다만 관련 법령에서 운영자의 책임을 줄이거나 없앨 수 없도록 정한 경우에는 그에 따라요',
  ]),
  ('제10조 (오픈소스 소프트웨어)', [
    '앱에는 오픈소스 소프트웨어와 글꼴이 들어 있고, 각각의 라이선스는 도움말의 오픈소스 라이선스에서 볼 수 있어요',
  ]),
  ('제11조 (준거법과 관할)', [
    '이 약관은 대한민국 법에 따라 해석해요',
    '앱 이용으로 다툼이 생기면 「민사소송법」에 따른 관할 법원에서 해결해요',
  ]),
  ('운영자 정보', [
    '- 운영자: $_blank',
    '- 문의: $_blank',
  ]),
];

const List<(String, List<String>)> _privacy = [
  ('1. 개요', [
    'FReader(이하 "앱")는 회원 가입·로그인이 없고, 이용자의 개인정보를 운영자 서버로 모으거나 보내지 않아요',
    '앱에서 다루는 정보는 모두 이용자 기기 안에만 저장돼요',
  ]),
  ('2. 기기 안에만 저장되는 정보', [
    '- 서재 목록(추가한 파일의 경로·이름·그룹·즐겨찾기), 읽던 위치, 메모, 북마크',
    '- 앱 설정(테마·언어·표시 방식 등)과 이용자가 추가한 글꼴 파일',
    '- 사생활 보호 잠금을 켠 경우 잠금에 쓰는 비밀번호·패턴 정보',
    '- 빠르게 열기 위해 미리 만들어 둔 쪽 그림·목차 등 임시 파일',
    '이 정보는 앱 설정의 캐시 지우기·데이터 지우기로 지우거나, 앱을 지우면 함께 지워져요',
  ]),
  ('3. 앱이 쓰는 권한', [
    '- 파일 접근: 기기의 문서·글꼴을 찾고 열고 서재에 추가하는 데 써요',
    '- 카메라 (선택): 문서 스캔에만 쓰고, 찍은 사진은 이용자 기기에만 저장돼요',
    '- 생체 인식 (선택): 사생활 보호 잠금을 풀 때 써요. 지문·얼굴 정보는 안드로이드가 처리하며 앱은 받지 않아요',
    '- 인터넷: 앱은 이 권한으로 이용자 파일이나 개인정보를 외부로 보내지 않아요',
    '선택 권한을 허용하지 않아도 그 기능을 빼고 앱을 쓸 수 있어요',
  ]),
  ('4. 유료 기능 결제', [
    '유료 기능 결제는 Google Play 결제 시스템으로 이루어져요',
    '카드 번호 등 결제 정보는 Google이 처리하며, 운영자는 이를 받거나 저장하지 않아요',
    '앱은 유료 기능을 열어 주기 위해 Google Play에서 구매 여부만 확인해요',
    'Google의 정보 처리는 Google 개인정보처리방침을 따라요',
  ]),
  ('5. 제3자 제공과 위탁', [
    '운영자는 이용자 정보를 받지 않으므로 제3자에게 제공하거나 처리를 위탁하지 않아요',
    '앱에는 광고나 이용 분석 도구가 들어 있지 않아요',
  ]),
  ('6. 아동의 개인정보', [
    '앱은 나이와 관계없이 개인정보를 모으지 않아요',
  ]),
  ('7. 이용자의 권리', [
    '이용자는 앱 설정의 데이터 지우기나 앱 삭제로 기기 안의 앱 정보를 언제든 지울 수 있어요',
    '권한은 안드로이드 설정에서 언제든 끌 수 있어요',
  ]),
  ('8. 방침의 변경', [
    '이 방침이 바뀌면 시행일과 바뀐 내용을 앱 안이나 Google Play 앱 페이지에 알려요',
  ]),
  ('9. 문의', [
    '- 운영자: $_blank',
    '- 이메일: $_blank',
  ]),
];
