// 사용법: node tool/setup.mjs
// Flutter 안드로이드 뼈대를 만들고 앱 설정과 rhwp 엔진을 넣는다. 여러 번 실행해도 된다.
import { execSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const run = (cmd, cwd = root) => execSync(cmd, { cwd, stdio: 'inherit' });

const ADMOB_TEST_APP_ID = 'ca-app-pub-3940256099942544~3347511713';
const MIME_TYPES = [
  'application/pdf',
  'application/x-hwp',
  'application/hwp',
  'application/haansofthwp',
  'application/vnd.hancom.hwp',
  'application/vnd.hancom.hwpx',
  'application/hwp+zip',
  'application/octet-stream',
];

export function patchManifest(xml) {
  if (xml.includes('easy-doc-viewer-patched')) return xml;
  const data = MIME_TYPES.map((m) => `                <data android:mimeType="${m}" />`).join('\n');
  const filters = `
            <!-- easy-doc-viewer-patched -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:scheme="content" />
${data}
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
${data}
            </intent-filter>
`;
  const meta = `
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="${ADMOB_TEST_APP_ID}" />
`;
  return xml
    .replace(/android:label="[^"]*"/, 'android:label="편한 문서 뷰어"\n        android:networkSecurityConfig="@xml/network_security_config"')
    .replace('</activity>', `${filters}        </activity>${meta}`)
    .replace(/<manifest([^>]*)>/, '<manifest$1>\n    <uses-permission android:name="android.permission.INTERNET" />');
}

function main() {
  run('flutter create --org app.easydoc --project-name easy_doc_viewer --platforms android --no-pub .');
  rmSync(path.join(root, 'test'), { recursive: true, force: true });

  const appMain = path.join(root, 'android/app/src/main');
  const kotlinDir = path.join(appMain, 'kotlin/app/easydoc/easy_doc_viewer');
  mkdirSync(kotlinDir, { recursive: true });
  copyFileSync(path.join(root, 'android_overlay/MainActivity.kt'), path.join(kotlinDir, 'MainActivity.kt'));
  mkdirSync(path.join(appMain, 'res/xml'), { recursive: true });
  copyFileSync(
    path.join(root, 'android_overlay/res/xml/network_security_config.xml'),
    path.join(appMain, 'res/xml/network_security_config.xml'),
  );
  const manifest = path.join(appMain, 'AndroidManifest.xml');
  writeFileSync(manifest, patchManifest(readFileSync(manifest, 'utf8')));

  const gradle = path.join(root, 'android/app/build.gradle.kts');
  if (existsSync(gradle)) {
    writeFileSync(gradle, readFileSync(gradle, 'utf8').replace(/minSdk\s*=\s*flutter\.minSdkVersion/, 'minSdk = 24'));
  }

  const temp = mkdtempSync(path.join(tmpdir(), 'rhwp-'));
  const packed = execSync(`npm pack "@rhwp/core@^0.8.7" --pack-destination "${temp}" --json`, { cwd: root }).toString();
  const name = JSON.parse(packed)[0].filename.replace(/^@/, '').replace('/', '-');
  execSync(`tar -xzf "${name}"`, { cwd: temp, stdio: 'inherit' });
  for (const file of ['rhwp.js', 'rhwp_bg.wasm']) {
    copyFileSync(path.join(temp, 'package', file), path.join(root, 'assets/rhwp', file));
  }
  rmSync(temp, { recursive: true, force: true });
  console.log('\n준비 완료: flutter pub get 후 flutter run 또는 flutter build apk 를 실행하세요.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
