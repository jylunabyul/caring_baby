# Gemini 버전 연결

`n8n/daddy-bob-jooseyo-gemini.json`을 새 워크플로우로 가져오세요. V3 DB 함수를 그대로 사용하므로 이미 V3 SQL을 적용했다면 SQL 변경은 필요 없습니다.

1. Supabase 및 Telegram 노드에는 기존 자격 증명을 선택합니다.
2. **Gemini intent and yes-no → Authentication: Generic Credential Type → Generic Auth Type: Header Auth → 새 자격 증명**을 만듭니다.
3. Header Auth의 **Name**은 `x-goog-api-key`, **Value**는 Google AI Studio에서 발급한 본인의 Gemini API 키입니다. 표시 이름이 아니라 헤더 이름 필드에 `x-goog-api-key`를 넣습니다. 키는 채팅·URL·JSON 본문에 넣지 마세요.
4. 기본 모델은 `gemini-2.5-flash`입니다. 이 모델을 사용할 수 있는 프로젝트 키가 필요합니다. 다른 모델로 바꾸면 structured output과 thinkingConfig 지원도 확인해야 합니다.
5. 기존 Telegram Trigger와 알림 스케줄을 Unpublish한 뒤 새 Gemini 워크플로우 하나만 Publish합니다.
6. `별이 120 먹었어` → 확인 질문 → `응` → `/history 별이`로 한 건만 기록되는지 확인합니다. 실제 수유 기록으로 저장되므로 테스트용 허위 기록을 남기지 마세요.

입력과 제한된 아이·기록 컨텍스트가 OpenAI 대신 Google Gemini API로 전송됩니다. 확인 토큰·Supabase 키는 모델 요청에 포함하지 않습니다. Google AI Studio 요금제에 따른 데이터 사용·보존 정책 및 API 한도를 확인하세요. Gemini도 요청/토큰 사용량 제한이 있으며 429·권한·모델 오류는 일반 이해 실패와 구분해 안내합니다. 자동 재시도로 중복 저장하지 않습니다.

자연어 명령, 확인·취소, 기록 수정·삭제, 여러 아이, 성장·재고 및 22:00~08:00 한국 시간 자동 알림 휴식은 V3와 동일합니다. 수면 설정은 수유 필요 여부를 판단하지 않습니다.

JSON 구조·Gemini 응답 변환·수치/명령 검증·오류 메시지는 모의 응답으로 테스트했습니다. 실제 Gemini 호출·프로젝트 권한·Telegram 발송은 자격 증명을 연결한 후 확인해야 합니다.
