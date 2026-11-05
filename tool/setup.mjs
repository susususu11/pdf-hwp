// 사용법: node tool/setup.mjs
// Flutter 안드로이드 뼈대를 만들고 앱 설정과 rhwp 엔진을 넣는다. 여러 번 실행해도 된다.
import { execSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
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

/** 패키지 구조가 달라도 진입 파일과 WASM을 찾아 앱이 쓰는 이름으로 복사한다. */
export function installEngine(extractedDir, dest) {
  const pkgDir = readdirSync(extractedDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => path.join(extractedDir, e.name))
    .find((d) => existsSync(path.join(d, 'package.json')));
  if (!pkgDir) throw new Error(`rhwp 패키지를 찾지 못했습니다: ${readdirSync(extractedDir).join(', ')}`);

  const files = readdirSync(pkgDir, { recursive: true }).map(String).map((f) => f.split(path.sep).join('/'));
  console.log(`rhwp 패키지 파일: ${files.join(', ')}`);
  const meta = JSON.parse(readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
  const declared = [meta.module, meta.main].filter(Boolean).map((f) => f.replace(/^\.\//, ''));
  const entry = [...declared, 'rhwp.js'].find((f) => files.includes(f)) ?? files.find((f) => /\.m?js$/.test(f));
  const wasm = files.find((f) => f.endsWith('.wasm'));
  if (!entry || !wasm) throw new Error(`rhwp 엔진 파일이 없습니다 (entry=${entry}, wasm=${wasm})`);

  for (const file of files.filter((f) => /\.m?js$/.test(f))) {
    mkdirSync(path.dirname(path.join(dest, file)), { recursive: true });
    copyFileSync(path.join(pkgDir, file), path.join(dest, file));
  }
  copyFileSync(path.join(pkgDir, entry), path.join(dest, 'rhwp.js'));
  copyFileSync(path.join(pkgDir, wasm), path.join(dest, 'rhwp_bg.wasm'));
  console.log(`rhwp 엔진 설치: ${entry}, ${wasm}`);
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
  copyFileSync(path.join(root, 'android_overlay/proguard-rules.pro'), path.join(root, 'android/app/proguard-rules.pro'));
  const gradleProperties = path.join(root, 'android/gradle.properties');
  const properties = readFileSync(gradleProperties, 'utf8');
  if (!properties.includes('android.enableR8.fullMode')) {
    writeFileSync(gradleProperties, `${properties.trimEnd()}\nandroid.enableR8.fullMode=false\n`);
  }
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
  installEngine(temp, path.join(root, 'assets/rhwp'));
  rmSync(temp, { recursive: true, force: true });
  console.log('\n준비 완료: flutter pub get 후 flutter run 또는 flutter build apk 를 실행하세요.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
