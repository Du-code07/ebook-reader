# FReader: 매니페스트에 카메라 권한(선택)과 연결 앱(파일 열기) 목록 등록을 넣음 (GitHub Actions에서 실행)
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'android.permission.CAMERA' not in s:
    s = s.replace('<application', '<uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
if 'FREADER_OPEN_WITH' not in s:
    mimes = [
        'application/pdf', 'application/epub+zip', 'text/plain',
        'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/x-hwp', 'application/hwp', 'application/haansofthwp', 'application/vnd.hancom.hwp',
        'application/x-hwpx', 'application/hwp+zip', 'application/haansofthwpx', 'application/vnd.hancom.hwpx',
        'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.ms-excel.sheet.macroEnabled.12',
        'application/x-cbz', 'application/vnd.comicbook+zip',
        'image/jpeg', 'image/png', 'image/webp',
    ]
    data = ''.join(f'<data android:mimeType="{m}"/>' for m in mimes)
    f1 = ('<!-- FREADER_OPEN_WITH: 다른 앱의 연결 앱 목록에 FReader가 보이게 -->'
          '<intent-filter><action android:name="android.intent.action.VIEW"/>'
          '<category android:name="android.intent.category.DEFAULT"/><category android:name="android.intent.category.BROWSABLE"/>'
          '<data android:scheme="content"/><data android:scheme="file"/>' + data + '</intent-filter>')
    # 형식을 모르는 파일(application/octet-stream)로 넘어오는 한글·만화 파일: 파일 이름 끝으로 구별
    exts = ['hwp', 'hwpx', 'cbz', 'epub', 'docx', 'pptx', 'xlsx']
    pats = ''.join(f'<data android:pathPattern=".*\\\\.{e}"/><data android:pathPattern=".*\\\\..*\\\\.{e}"/>' for e in exts)
    f2 = ('<intent-filter><action android:name="android.intent.action.VIEW"/>'
          '<category android:name="android.intent.category.DEFAULT"/><category android:name="android.intent.category.BROWSABLE"/>'
          '<data android:scheme="content"/><data android:scheme="file"/><data android:host="*"/>'
          '<data android:mimeType="application/octet-stream"/>' + pats + '</intent-filter>')
    i = s.index('</activity>')
    s = s[:i] + f1 + f2 + s[i:]
open(p, 'w', encoding='utf-8').write(s)
