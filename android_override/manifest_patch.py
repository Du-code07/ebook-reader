# 이리ERI: 매니페스트에 카메라 권한(선택)과 연결 앱(파일 열기) 목록 등록을 넣음 (GitHub Actions에서 실행)
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 쓰지 않는 권한은 빼 둠 (저장소 읽기·모든 파일 접근·설치된 앱 목록)
import re
s = re.sub(r'\s*<uses-permission[^>]*(READ_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|QUERY_ALL_PACKAGES)[^>]*/>', '', s)
if 'android.permission.CAMERA' not in s:
    s = s.replace('<application', '<uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
# 앱 잠금: 지문·얼굴 인식으로 잠금 해제
if 'android.permission.USE_BIOMETRIC' not in s:
    s = s.replace('<application', '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>\n    <application', 1)
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
    ]
    data = ''.join(f'<data android:mimeType="{m}"/>' for m in mimes)
    f1 = ('<!-- FREADER_OPEN_WITH: 다른 앱의 연결 앱 목록에 이리ERI가 보이게 -->'
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
# 문서 스캔: 스캔 카메라 화면 + 찍은 사진을 넘기는 통로
if 'DocumentCameraActivity' not in s:
    scan = ('<activity android:name=".DocumentCameraActivity" android:screenOrientation="portrait" '
            'android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" android:exported="false"/>'
            '<provider android:name=".ScanFileProvider" android:authorities="${applicationId}.scanprovider" '
            'android:exported="false" android:grantUriPermissions="true"/>')
    i = s.rindex('</application>')
    s = s[:i] + scan + s[i:]
# 공유: 앱 안 파일을 다른 앱에 넘기는 통로 (FileProvider)
if 'freader.fileprovider' not in s:
    prov = ('<provider android:name="androidx.core.content.FileProvider" '
            'android:authorities="${applicationId}.freader.fileprovider" android:exported="false" android:grantUriPermissions="true">'
            '<meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/freader_share_paths"/></provider>')
    i = s.rindex('</application>')
    s = s[:i] + prov + s[i:]
import os
xml_dir = os.path.join(os.path.dirname(p), 'res', 'xml')
os.makedirs(xml_dir, exist_ok=True)
open(os.path.join(xml_dir, 'freader_share_paths.xml'), 'w', encoding='utf-8').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<paths>'
    '<files-path name="files" path="."/><cache-path name="cache" path="."/>'
    '<external-path name="external" path="."/><external-files-path name="external_files" path="."/>'
    '<root-path name="root" path="."/></paths>\n')
open(p, 'w', encoding='utf-8').write(s)
