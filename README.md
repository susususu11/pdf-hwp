# 편한 문서 뷰어 (프로토타입)

HWP·HWPX를 휴대폰 안에서 PDF로 바꿔 보여 주고, PDF는 그대로 보여 주는 안드로이드 앱입니다.
파일은 서버로 전송하지 않습니다.

## 들어 있는 기능
- 앱 안에서 문서 선택, 카카오톡 등에서 "다음 앱으로 열기"와 공유
- HWP·HWPX → PDF 변환, 변환본 저장 (같은 문서는 다시 변환하지 않음)
- 글자가 겹치면 "내용이 가려졌을 수 있습니다" 경고
- 텍스트로 보기
- Word(.docx), Excel(.xlsx, .xls), PowerPoint(.pptx), 이미지, 텍스트 파일 보기
- 문서와 겹치지 않는 하단 고정 배너 (Google 시험 광고)
- 한 번 결제로 광고를 없애는 인앱 상품 `remove_ads`와 구매 복원

## 방법 1: PC 설치 없이 APK 받기
1. GitHub에 새 저장소를 만들고 이 폴더의 파일을 모두 올립니다. 숨김 폴더 `.github`도 포함해야 합니다.
2. 저장소의 Actions 탭에서 `Build APK` 실행이 끝나기를 기다립니다.
3. 실행 결과의 Artifacts에서 `easy-doc-viewer-apk`를 내려받아 압축을 풉니다.
4. `app-release.apk`를 안드로이드 휴대폰에 옮겨 설치합니다.

## 방법 2: PC에서 직접 빌드
Flutter, Android Studio, Node.js가 필요합니다.

```bash
node tool/setup.mjs
flutter pub get
flutter run
```

## 변환 흐름 시험
`assets/converter/core.js`가 겹침 감지와 PDF 생성을 담당합니다.
`tool/browser_test.mjs`는 rhwp CLI의 SVG로 Chromium에서 이 흐름을 검사합니다.

## 출시 전 할 일
- 자동 시험 코드(`_runSelfTest`, `assets/selftest`)와 `proguard-rules.pro`의 진단 설정 제거
- Play Console에 관리형 인앱 상품 `remove_ads` 생성 (없으면 결제 창에 안내 문구만 나온다)
- `lib/screens.dart`의 배너 ID와 `tool/setup.mjs`의 AdMob 앱 ID를 실제 값으로 교체
- 업로드 서명 키 설정, 개인정보 처리방침 작성
- 앱 안에 `THIRD_PARTY_NOTICES.md` 내용 표시
- 앱 이름과 설명의 상표 표현 점검

## 현재 한계
- PDF 페이지는 그림이라 PDF 안에서 글자 선택이 되지 않습니다. 텍스트 보기를 쓰세요.
- 글꼴은 휴대폰에 설치된 글꼴을 씁니다.
- rhwp 표 배치 문제로 일부 문서는 내용이 가려질 수 있습니다.
