# Baby Feed Assistant (n8n + Supabase)

아이별 분유 수유 기록, 다음 수유 시점 알림, 참고 섭취량 계산, 분유 재고 알림을 위한 MVP 구성입니다. Telegram을 1차 메신저로 사용합니다. 데이터와 아이 프로필은 Supabase에 저장하고, 알림 및 텔레그램 명령 처리는 n8n이 담당합니다.

## 포함 파일

- `supabase/schema.sql`: 테이블, Row Level Security(RLS), 아이별 데이터 격리, 수유 기록 RPC
- `n8n/telegram-feed-command.json`: `/feed 아이이름 120` 기록 및 `/help` 안내
- `n8n/feeding-reminders.json`: 주기적으로 아이별 다음 수유 예정 알림 전송. Loop Over Items 노드로 아이별 반복 처리
- `n8n/inventory-reminders.json`: 재고 임계치 확인 후 아이별 구매 알림 전송
- `app/index.html`: Supabase 로그인 기반의 모바일 우선 기록 화면

## 설치 순서

1. Supabase SQL Editor에서 `supabase/schema.sql`을 실행합니다.
2. Supabase Auth에서 이메일 로그인(Magic Link)을 켭니다. `app/config.example.js`를 `app/config.js`로 복사한 뒤 `SUPABASE_URL`, `SUPABASE_ANON_KEY`를 프로젝트의 공개 URL과 publishable/anon key로 바꿉니다. 앱을 정적 호스팅하고 허용 URL을 Auth Redirect URL에 등록합니다.
3. `children`에 아이별 이름, 생년월일, 최근 체중(kg), 예상 수유 간격(분)을 입력합니다. 먼저 웹 앱으로 로그인한 뒤 데이터 화면에서 직접 추가하거나 SQL Editor에서 `owner_id`를 현재 사용자 UUID로 지정해 등록할 수 있습니다.
4. `formula_inventory`에 분유 제품, 현재 재고(조제 후 환산 ml), 재주문 기준(ml), 한 통 환산량(ml), 배송 여유일을 입력합니다. 포장지의 조제 비율에 따라 환산량을 계산하세요.
5. n8n에 JSON 워크플로우를 가져옵니다. self-hosted n8n에서는 `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`을 환경변수로 설정합니다. n8n Cloud에서는 각 HTTP Request 노드의 URL과 인증 헤더를 프로젝트 값과 안전한 자격 증명에 연결하고, Telegram Trigger에 봇 자격 증명을 선택합니다. 실제 키가 든 워크플로우 파일은 내보내거나 공유하지 마세요. 워크플로우를 활성화합니다.
6. Telegram에서 봇에 먼저 `/start`를 보냅니다. n8n 실행 기록에서 채팅 ID를 확인한 뒤 앱의 **텔레그램 연결** 버튼에 입력합니다. 채팅 ID는 아이가 아니라 보호자 계정의 연락처입니다.

## Telegram 명령

- `/feed 지온 120` — 해당 아이에게 120ml 먹인 기록. 이름은 `children.name`과 정확히 일치해야 합니다.
- `/help` — 도움말

웹 앱에서는 아이를 선택하고 양을 입력해 기록합니다. 저장 성공 시 직전 수유 시각과 다음 예정 시각을 표시합니다.

## 수유량 및 시간 계산

앱은 출생 후 첫 주가 지난 6개월 미만 영아에 대해 `체중(kg) × 150ml/일`을 참고 중심값으로 계산합니다. 기본 범위는 150–200ml/kg/일이며, 목표 횟수로 나눠 1회 참고량을 표시합니다. 하루 960ml 이상으로 계산되면 소아과 확인 문구를 표시합니다. 미국소아과학회(AAP)는 많은 아기가 보통 24시간 32oz(약 960ml)를 넘지 않는다고 안내하지만, 아기마다 필요한 양은 다릅니다. 이 값은 처방이 아니며, 미숙아·저체중·질환·성장부진·의료진의 개별 지시가 있으면 이 앱의 추정치를 사용하지 마세요.

다음 알림 시각은 마지막 기록 시각 + 아이별 설정 간격으로 계산합니다. 알림은 식사 지시가 아니라 보호자가 기록한 패턴에 대한 리마인더입니다. 아기의 배고픔 신호와 의료진의 지침을 우선하세요. 예정 시각 알림 후 60분 안에는 중복 알림을 보내지 않습니다.

분유 재고는 남은 조제 환산량에서 실제 먹인 양을 차감합니다. 재고 임계치까지 남은 사용일수를 최근 7일 기록으로 추정합니다. 재고 입력을 마친 뒤 첫 7일은 알림에 재고량만 표시됩니다.

## KakaoTalk 확장

기록과 사용자 데이터는 메신저에 종속되지 않도록 Supabase에 둡니다. 카카오톡으로 보호자에게 자동 알림을 보내려면 카카오톡 채널을 통한 알림톡 등 비즈니스 발송 경로를 별도로 붙이는 구성이 적합합니다. 이는 채널/발송 서비스 설정과 메시지 템플릿 준비가 필요합니다. Kakao Developers의 일반 카카오톡 메시지 API는 서비스 사용자가 본인 또는 같은 서비스의 친구에게 보내는 흐름이므로, 봇의 임의 수신자 메시지 기능과 동일하지 않습니다.

## 개인정보와 운영

- 서비스 롤 키는 브라우저에 절대 넣지 않습니다. 브라우저는 공개 anon key와 로그인 세션을 사용하고, n8n만 서비스 롤 권한으로 RPC를 호출합니다.
- 이름, 생년월일, 체중은 민감한 아동 데이터입니다. 꼭 필요한 정보만 저장하고, n8n 실행 이력의 보존 기간을 짧게 설정하며, 공유/테스트용 워크플로우 JSON에 실제 토큰을 포함하지 마세요.
- 이 MVP는 로컬에서 만든 구성 초안입니다. Supabase 프로젝트와 n8n 계정 자격증명은 연결되어 있지 않아 실제 배포 또는 계정 변경은 하지 않았습니다.

## 출처

- American Academy of Pediatrics / HealthyChildren.org, [Amount and Schedule of Baby Formula Feedings](https://www.healthychildren.org/English/ages-stages/baby/formula-feeding/Pages/amount-and-schedule-of-baby-formula-feedings.aspx)
- NHS, [Bottle feeding your baby](https://www.nhs.uk/best-start-in-life/baby/feeding-your-baby/bottle-feeding/bottle-feeding-your-baby/)
- n8n, [Telegram node](https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.telegram/)
- Telegram, [Bot API](https://core.telegram.org/bots/api)
- Kakao Developers, [카카오톡 메시지 FAQ](https://developers.kakao.com/docs/ko/kakaotalk-message/faq)

## 로컬 실행 및 저장소 설정

Node.js 22 이상, Python 3를 사용합니다. 별도 패키지 설치나 빌드는 필요 없습니다.

```sh
git clone https://github.com/jylunabyul/caring_baby.git
cd caring_baby
cp app/config.example.js app/config.js
# app/config.js에 Supabase 공개 연결 정보 입력
python3 -m http.server 8000 --directory app
```

브라우저에서 http://localhost:8000 을 열고, Supabase Auth Redirect URLs에도 해당 주소를 등록하세요.
설정 파일이 없으면 로그인 대신 설정 안내가 표시됩니다. `app/config.js`와 `.env` 파일은 Git에서 제외합니다.
정적 호스팅 시에도 배포 대상에 `config.js`를 별도로 제공해야 합니다. GitHub에 업로드하는 것만으로 앱이 배포되지는 않습니다.

```sh
node scripts/check.mjs
```

GitHub Actions에서 JavaScript 문법과 n8n JSON/연결 구조를 자동 검증합니다.
DB 실행, 이메일 로그인, Telegram 발송까지 검증하는 테스트는 아니므로 서비스 연결 후 실제 수유 기록과 알림을 확인하세요.
n8n 환경변수 이름은 `n8n/.env.example`을 참고하고 실제 값은 호스팅 환경에 설정하세요.
워크플로우는 비활성 상태로 제공하며, Telegram Trigger의 봇 자격증명도 직접 연결해야 합니다.
