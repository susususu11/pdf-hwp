import assert from 'node:assert';
import { patchManifest } from './setup.mjs';
const before = `<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="easy_doc_viewer"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MAIN"/></intent-filter>
        </activity>
        <meta-data android:name="flutterEmbedding" android:value="2" />
    </application>
</manifest>`;
const after = patchManifest(before);
assert(after.includes('networkSecurityConfig'));
assert(after.indexOf('android.intent.action.SEND') < after.indexOf('</activity>'));
assert(after.indexOf('gms.ads.APPLICATION_ID') > after.indexOf('</activity>'));
assert(after.indexOf('uses-permission') < after.indexOf('<application'));
assert.strictEqual(patchManifest(after), after);
console.log('manifest ok');
